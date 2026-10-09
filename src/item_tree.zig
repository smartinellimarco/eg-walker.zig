const std = @import("std");
const causal_graph = @import("causal_graph.zig");

const Lv = causal_graph.Lv;
const none = causal_graph.none;

pub const not_yet_inserted: i32 = -1;
pub const inserted: i32 = 0;
pub const deleted: i32 = 1;

const fanout = 16;


pub const Item = struct {
    // For placeholders this is the first of a run of locally allocated ids.
    lv: Lv,
    run_len: u32 = 1,
    // -1 not yet inserted, 0 inserted, n>0 deleted by n concurrent events.
    cur_state: i32 = inserted,
    ever_deleted: bool = false,
    origin_left: Lv = none,
    right_parent: Lv = none,
    // Where this item sits right now, so its counts can be fixed up the tree.
    leaf: *Node = undefined,

    pub fn widthInPrepare(self: Item) u32 {
        return if (self.cur_state == inserted) self.run_len else 0;
    }

    pub fn widthInEffect(self: Item) u32 {
        return if (self.ever_deleted) 0 else self.run_len;
    }

    fn holds(self: Item, id: Lv) bool {
        return id >= self.lv and id - self.lv < self.run_len;
    }

    fn counts(self: Item) Counts {
        return .{
            .items = 1,
            .present = @intFromBool(self.cur_state != not_yet_inserted),
            .prepare = self.widthInPrepare(),
            .effect = self.widthInEffect(),
        };
    }

    // Typing produces runs where each byte's left origin is the one before
    // it, which is exactly when a run can hold them all as one item.
    fn tryAppend(a: *Item, b: Item) bool {
        if (a.cur_state != b.cur_state or a.ever_deleted != b.ever_deleted) return false;
        if (a.right_parent != b.right_parent) return false;
        if (a.lv + a.run_len != b.lv) return false;
        if (b.origin_left != b.lv - 1) return false;
        a.run_len += b.run_len;
        return true;
    }
};

const Counts = struct {
    items: u32 = 0,
    // Items that already existed in some version, which is where an insert
    // stops looking for its right parent.
    present: u32 = 0,
    prepare: u32 = 0,
    effect: u32 = 0,

    fn add(self: *Counts, other: Counts) void {
        self.items += other.items;
        self.present += other.present;
        self.prepare += other.prepare;
        self.effect += other.effect;
    }

    fn sub(self: *Counts, other: Counts) void {
        self.items -= other.items;
        self.present -= other.present;
        self.prepare -= other.prepare;
        self.effect -= other.effect;
    }
};

pub const Node = struct {
    parent: ?*Node = null,
    parent_idx: u16 = 0,
    level: u8,
    len: u16 = 0,
    counts: [fanout]Counts = @splat(.{}),
    // Leaves index into the item store, branches point at child nodes.
    items: [fanout]u32 = @splat(0),
    children: [fanout]*Node = undefined,

    fn total(self: Node) Counts {
        var sum: Counts = .{};
        for (self.counts[0..self.len]) |child| sum.add(child);
        return sum;
    }
};

pub const Loc = struct {
    leaf: *Node,
    idx: u16,
};

pub const Cursor = struct {
    loc: Loc,
    effect_pos: u32,
};

/// The order statistic tree of the paper: a B-tree over run-length encoded
/// items where every branch knows how many bytes its subtree holds in the
/// prepare version and in the effect version. Items themselves never move, so
/// ids can point straight at them.
pub const Tree = struct {
    gpa: std.mem.Allocator,
    // Nodes come from an arena: they are never freed one at a time, and
    // collapsing at a critical version is a reset rather than a walk.
    arena: std.heap.ArenaAllocator,
    root: *Node,
    store: std.ArrayList(Item) = .empty,
    // Event ids run from `base` upwards without gaps, so the item holding each
    // one is a plain lookup. Splits only ever push bytes to the right, so
    // a stale entry is repaired by walking on.
    owners: std.ArrayList(u32) = .empty,
    base: Lv = 0,
    // Placeholder bytes get ids from the top of the space downwards. Only
    // the ones that are actually pointed at get an entry, because a placeholder
    // can be as long as the whole document.
    locals: std.AutoHashMapUnmanaged(Lv, u32) = .empty,
    // Placeholders and bytes deleted out of them need ids no event will
    // ever use, so they are handed out from the top downwards.
    local_next: Lv = none,

    pub fn init(gpa: std.mem.Allocator) !Tree {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const root = try newNode(arena.allocator(), 0);

        return .{ .gpa = gpa, .arena = arena, .root = root };
    }

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
        self.store.deinit(self.gpa);
        self.owners.deinit(self.gpa);
        self.locals.deinit(self.gpa);
    }

    pub fn clear(self: *Tree, base: Lv) !void {
        _ = self.arena.reset(.retain_capacity);
        self.root = try newNode(self.arena.allocator(), 0);
        self.store.clearRetainingCapacity();
        self.owners.clearRetainingCapacity();
        self.locals.clearRetainingCapacity();
        self.base = base;
        self.local_next = none;
    }

    pub fn start(self: *Tree) Loc {
        var node = self.root;
        while (node.level > 0) node = node.children[0];
        return .{ .leaf = node, .idx = 0 };
    }

    pub fn item(self: *Tree, loc: Loc) *Item {
        return &self.store.items[loc.leaf.items[loc.idx]];
    }

    pub fn atEnd(self: *Tree, loc: Loc) bool {
        _ = self;
        return loc.idx >= loc.leaf.len;
    }

    /// Whether the byte at `loc` is visible in the prepare version, without
    /// reading the item itself.
    pub fn visible(self: *Tree, loc: Loc) bool {
        _ = self;
        return loc.leaf.counts[loc.idx].prepare > 0;
    }

    pub fn effectWidth(self: *Tree, loc: Loc) u32 {
        _ = self;
        return loc.leaf.counts[loc.idx].effect;
    }

    pub fn nextLoc(self: *Tree, loc: Loc) Loc {
        _ = self;
        if (loc.idx + 1 < loc.leaf.len) return .{ .leaf = loc.leaf, .idx = loc.idx + 1 };
        if (nextLeaf(loc.leaf)) |leaf| return .{ .leaf = leaf, .idx = 0 };
        return .{ .leaf = loc.leaf, .idx = loc.leaf.len };
    }

    /// The first item at or after `loc` that is not in the not-yet-inserted
    /// state. Walking there item by item would be linear in the number of
    /// concurrent inserts sitting in front of it.
    pub fn nextPresent(self: *Tree, loc: Loc) Loc {
        var idx = loc.idx;
        while (idx < loc.leaf.len) : (idx += 1) {
            if (loc.leaf.counts[idx].present > 0) return .{ .leaf = loc.leaf, .idx = idx };
        }

        var node = loc.leaf;
        while (node.parent) |parent| {
            var child = node.parent_idx + 1;
            while (child < parent.len) : (child += 1) {
                if (parent.counts[child].present > 0) return firstPresent(parent.children[child]);
            }
            node = parent;
        }

        return self.endLoc();
    }

    fn firstPresent(node: *Node) Loc {
        var walk = node;
        while (walk.level > 0) {
            var child: u16 = 0;
            while (walk.counts[child].present == 0) child += 1;
            walk = walk.children[child];
        }

        var idx: u16 = 0;
        while (walk.counts[idx].present == 0) idx += 1;
        return .{ .leaf = walk, .idx = idx };
    }

    pub fn endLoc(self: *Tree) Loc {
        var node = self.root;
        while (node.level > 0) node = node.children[node.len - 1];
        return .{ .leaf = node, .idx = node.len };
    }

    fn prevLoc(self: *Tree, loc: Loc) ?Loc {
        _ = self;
        if (loc.idx > 0) return .{ .leaf = loc.leaf, .idx = loc.idx - 1 };
        const leaf = prevLeaf(loc.leaf) orelse return null;
        return .{ .leaf = leaf, .idx = leaf.len - 1 };
    }

    /// Number of items before `loc`, which is what orders two positions.
    pub fn rankOf(self: *Tree, loc: Loc) u32 {
        _ = self;
        var rank: u32 = loc.idx;
        var node = loc.leaf;
        while (node.parent) |parent| {
            for (parent.counts[0..node.parent_idx]) |child| rank += child.items;
            node = parent;
        }
        return rank;
    }

    fn allocLocal(self: *Tree, run_len: u32) Lv {
        self.local_next -= run_len;
        return self.local_next;
    }

    /// Seeds a replay with the document as it was at a critical version. Its
    /// contents are unknown, only its length matters.
    pub fn seedPlaceholder(self: *Tree, run_len: u32) !void {
        if (run_len == 0) return;
        _ = try self.insertAt(self.start(), .{ .lv = self.allocLocal(run_len), .run_len = run_len });
    }

    pub fn findByPreparePos(self: *Tree, pos: u32) !Cursor {
        while (true) {
            var node = self.root;
            var remaining = pos;
            var effect_pos: u32 = 0;

            while (node.level > 0) {
                var child: u16 = 0;
                while (child + 1 < node.len and remaining > node.counts[child].prepare) : (child += 1) {
                    remaining -= node.counts[child].prepare;
                    effect_pos += node.counts[child].effect;
                }
                node = node.children[child];
            }


            var idx: u16 = 0;
            while (remaining > 0) {
                std.debug.assert(idx < node.len);
                // The leaf already knows each item's width, so walking it needs
                // no trip to the item store.
                const width = node.counts[idx].prepare;

                if (width > remaining) {
                    // The position falls inside a run, so the run has to give way.
                    try self.splitAt(.{ .leaf = node, .idx = idx }, remaining);
                    break;
                }

                remaining -= width;
                effect_pos += node.counts[idx].effect;
                idx += 1;
            }

            if (remaining > 0) continue;
            return .{ .loc = normalize(.{ .leaf = node, .idx = idx }), .effect_pos = effect_pos };
        }
    }

    pub fn locOfId(self: *Tree, id: Lv) Loc {
        var loc = self.locOfItem(self.slotOf(id));
        while (!self.item(loc).holds(id)) loc = self.nextLoc(loc);

        self.remember(id, loc.leaf.items[loc.idx]);
        return loc;
    }

    fn slotOf(self: *Tree, id: Lv) u32 {
        if (isLocal(id)) return self.locals.get(id).?;
        return self.owners.items[id - self.base];
    }

    fn remember(self: *Tree, id: Lv, stored: u32) void {
        if (isLocal(id)) {
            self.locals.putAssumeCapacity(id, stored);
        } else {
            self.owners.items[id - self.base] = stored;
        }
    }

    fn locOfItem(self: *Tree, store_idx: u32) Loc {
        const leaf = self.store.items[store_idx].leaf;
        var idx: u16 = 0;
        while (leaf.items[idx] != store_idx) idx += 1;
        return .{ .leaf = leaf, .idx = idx };
    }

    /// Splits whatever run holds `id` until that byte is an item of its
    /// own, and returns where it sits.
    pub fn isolate(self: *Tree, id: Lv) !Loc {
        var loc = self.locOfId(id);

        const offset = id - self.item(loc).lv;
        if (offset > 0) {
            try self.splitAt(loc, offset);
            loc = self.locOfId(id);
        }
        if (self.item(loc).run_len > 1) {
            try self.splitAt(loc, 1);
            loc = self.locOfId(id);
        }

        return loc;
    }

    /// The id of the last byte before `loc`.
    pub fn idLeftOf(self: *Tree, loc: Loc) Lv {
        const previous = self.prevLoc(loc) orelse return none;
        const left = self.item(previous);
        return left.lv + left.run_len - 1;
    }

    pub fn setCurState(self: *Tree, loc: Loc, delta: i32) void {
        const target = self.item(loc);
        const before = target.counts();
        target.cur_state += delta;
        self.fixCounts(loc, before, target.counts());
    }

    pub fn markDeleted(self: *Tree, loc: Loc) void {
        const target = self.item(loc);
        const before = target.counts();
        target.ever_deleted = true;
        target.cur_state = deleted;
        self.fixCounts(loc, before, target.counts());
    }

    fn fixCounts(self: *Tree, loc: Loc, before: Counts, after: Counts) void {
        _ = self;
        var node = loc.leaf;
        var idx = loc.idx;
        while (true) {
            node.counts[idx].sub(before);
            node.counts[idx].add(after);
            const parent = node.parent orelse return;
            idx = node.parent_idx;
            node = parent;
        }
    }

    /// Splits the run at `loc` so that the first part is `offset` long.
    pub fn splitAt(self: *Tree, loc: Loc, offset: u32) !void {
        const head = self.item(loc);
        std.debug.assert(offset > 0 and offset < head.run_len);

        var tail = head.*;
        tail.lv += offset;
        tail.run_len -= offset;
        // Inside a run every byte's left origin is the one before it.
        tail.origin_left = head.lv + offset - 1;

        const before = head.counts();
        head.run_len = offset;
        self.fixCounts(loc, before, self.item(loc).counts());

        // Two ends for the tail, one boundary for the head.
        if (isLocal(tail.lv)) try self.locals.ensureUnusedCapacity(self.gpa, 3);

        // Taken before the insert, which can move items between leaves.
        const head_stored = loc.leaf.items[loc.idx];
        const placed = try self.insertRaw(.{ .leaf = loc.leaf, .idx = loc.idx + 1 }, tail);

        self.indexIds(tail, placed.leaf.items[placed.idx]);
        // The head keeps its own entries, but its last byte is a boundary now.
        self.remember(tail.lv - 1, head_stored);
    }

    /// Inserts before `loc`, folding the new item into the run on its left when
    /// they are contiguous.
    pub fn insertAt(self: *Tree, loc: Loc, new_item: Item) !Loc {
        try self.reserveSlots(new_item);

        if (self.prevLoc(loc)) |previous| {
            const left = self.item(previous);
            const before = left.counts();
            if (Item.tryAppend(left, new_item)) {
                self.fixCounts(previous, before, self.item(previous).counts());
                self.indexIds(new_item, previous.leaf.items[previous.idx]);
                return previous;
            }
        }

        const placed = try self.insertRaw(loc, new_item);
        self.indexIds(new_item, placed.leaf.items[placed.idx]);
        return placed;
    }

    fn reserveSlots(self: *Tree, new_item: Item) !void {
        if (isLocal(new_item.lv)) {
            try self.locals.ensureUnusedCapacity(self.gpa, 2);
        } else {
            const end = new_item.lv + new_item.run_len - self.base;
            if (self.owners.items.len < end) try self.owners.resize(self.gpa, end);
        }
    }

    fn indexIds(self: *Tree, new_item: Item, stored: u32) void {
        if (isLocal(new_item.lv)) {
            // Origins only ever point at the ends of a placeholder piece.
            self.locals.putAssumeCapacity(new_item.lv, stored);
            self.locals.putAssumeCapacity(new_item.lv + new_item.run_len - 1, stored);
        } else {
            @memset(self.owners.items[new_item.lv - self.base ..][0..new_item.run_len], stored);
        }
    }

    /// Every byte of a run becomes findable. Deletes need this: the events
    /// that removed them are replayed one id at a time.
    pub fn indexEveryId(self: *Tree, loc: Loc) !void {
        const target = self.item(loc).*;
        if (!isLocal(target.lv)) return;

        try self.locals.ensureUnusedCapacity(self.gpa, target.run_len);
        const stored = loc.leaf.items[loc.idx];
        for (0..target.run_len) |i| self.locals.putAssumeCapacity(target.lv + @as(Lv, @intCast(i)), stored);
    }

    fn insertRaw(self: *Tree, loc: Loc, new_item: Item) !Loc {
        const store_idx: u32 = @intCast(self.store.items.len);
        try self.store.append(self.gpa, new_item);

        var leaf = loc.leaf;
        var idx = loc.idx;

        if (leaf.len == fanout) {
            const sibling = try self.splitNode(leaf);
            if (idx > leaf.len) {
                idx -= leaf.len;
                leaf = sibling;
            }
        }

        var i = leaf.len;
        while (i > idx) : (i -= 1) {
            leaf.items[i] = leaf.items[i - 1];
            leaf.counts[i] = leaf.counts[i - 1];
        }
        leaf.items[idx] = store_idx;
        leaf.counts[idx] = new_item.counts();
        leaf.len += 1;

        self.store.items[store_idx].leaf = leaf;

        var node = leaf;
        while (node.parent) |parent| {
            parent.counts[node.parent_idx].add(new_item.counts());
            node = parent;
        }

        return .{ .leaf = leaf, .idx = idx };
    }

    fn splitNode(self: *Tree, node: *Node) std.mem.Allocator.Error!*Node {
        const sibling = try newNode(self.arena.allocator(), node.level);
        const keep = node.len / 2;
        const moved = node.len - keep;

        @memcpy(sibling.counts[0..moved], node.counts[keep..node.len]);
        if (node.level == 0) {
            @memcpy(sibling.items[0..moved], node.items[keep..node.len]);
        } else {
            @memcpy(sibling.children[0..moved], node.children[keep..node.len]);
        }
        sibling.len = moved;
        node.len = keep;

        if (node.level == 0) {
            for (sibling.items[0..moved]) |store_idx| self.store.items[store_idx].leaf = sibling;
        } else {
            for (sibling.children[0..moved], 0..) |child, i| {
                child.parent = sibling;
                child.parent_idx = @intCast(i);
            }
        }

        if (node.parent) |parent| {
            parent.counts[node.parent_idx] = node.total();
            try self.insertChild(parent, node.parent_idx + 1, sibling);
        } else {
            const root = try newNode(self.arena.allocator(), node.level + 1);
            root.len = 1;
            root.children[0] = node;
            root.counts[0] = node.total();
            node.parent = root;
            node.parent_idx = 0;
            self.root = root;
            try self.insertChild(root, 1, sibling);
        }

        return sibling;
    }

    fn insertChild(self: *Tree, node: *Node, at: u16, child: *Node) std.mem.Allocator.Error!void {
        var parent = node;
        var idx = at;

        if (parent.len == fanout) {
            const sibling = try self.splitNode(parent);
            if (idx > parent.len) {
                idx -= parent.len;
                parent = sibling;
            }
        }

        var i = parent.len;
        while (i > idx) : (i -= 1) {
            parent.children[i] = parent.children[i - 1];
            parent.counts[i] = parent.counts[i - 1];
            parent.children[i].parent_idx = i;
        }
        parent.children[idx] = child;
        parent.counts[idx] = child.total();
        parent.len += 1;

        child.parent = parent;
        child.parent_idx = idx;

        // A split rewrites the totals of the nodes it touched, so the branch
        // above them is brought back in line.
        var walk = parent;
        while (walk.parent) |grandparent| {
            grandparent.counts[walk.parent_idx] = walk.total();
            walk = grandparent;
        }
    }
};

// Local ids are handed out from the top of the id space downwards, far above
// anything an event graph will reach.
fn isLocal(id: Lv) bool {
    return id > std.math.maxInt(Lv) / 2;
}

fn normalize(loc: Loc) Loc {
    if (loc.idx < loc.leaf.len) return loc;
    if (nextLeaf(loc.leaf)) |leaf| return .{ .leaf = leaf, .idx = 0 };
    return loc;
}

fn nextLeaf(leaf: *Node) ?*Node {
    var node = leaf;
    while (node.parent) |parent| {
        if (node.parent_idx + 1 < parent.len) {
            var down = parent.children[node.parent_idx + 1];
            while (down.level > 0) down = down.children[0];
            return down;
        }
        node = parent;
    }
    return null;
}

fn prevLeaf(leaf: *Node) ?*Node {
    var node = leaf;
    while (node.parent) |parent| {
        if (node.parent_idx > 0) {
            var down = parent.children[node.parent_idx - 1];
            while (down.level > 0) down = down.children[down.len - 1];
            return down;
        }
        node = parent;
    }
    return null;
}

fn newNode(gpa: std.mem.Allocator, level: u8) !*Node {
    const node = try gpa.create(Node);
    node.* = .{ .level = level };
    return node;
}

const testing = std.testing;

test "positions skip retreated and deleted items" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();

    var loc = tree.start();
    loc = tree.nextLoc(try tree.insertAt(loc, .{ .lv = 0 }));
    loc = tree.nextLoc(try tree.insertAt(loc, .{ .lv = 1, .cur_state = not_yet_inserted }));
    loc = tree.nextLoc(try tree.insertAt(loc, .{ .lv = 2, .cur_state = deleted, .ever_deleted = true }));
    _ = try tree.insertAt(loc, .{ .lv = 3 });

    // Stopping before the invisible items is what lets a delete skip them.
    try testing.expectEqual(@as(u32, 1), (try tree.findByPreparePos(1)).effect_pos);
    try testing.expectEqual(@as(u32, 3), (try tree.findByPreparePos(2)).effect_pos);
}

test "a position inside a placeholder splits it" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();

    try tree.seedPlaceholder(10);
    const base = tree.item(tree.start()).lv;

    const cursor = try tree.findByPreparePos(4);

    try testing.expectEqual(@as(u32, 4), cursor.effect_pos);
    try testing.expectEqual(@as(u32, 1), tree.rankOf(cursor.loc));
    try testing.expectEqual(@as(u32, 4), tree.item(tree.start()).run_len);
    try testing.expectEqual(base + 3, tree.idLeftOf(cursor.loc));
    try testing.expectEqual(@as(u32, 1), tree.rankOf(tree.locOfId(base + 4)));
}

test "counts survive node splits" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();

    var loc = tree.start();
    var lv: Lv = 0;
    // Right parents that differ keep every byte in its own item.
    while (lv < 200) : (lv += 1) {
        loc = tree.nextLoc(try tree.insertAt(loc, .{ .lv = lv, .right_parent = lv }));
    }

    try testing.expectEqual(@as(u32, 200), tree.root.total().items);
    try testing.expectEqual(@as(u32, 200), tree.root.total().prepare);

    const cursor = try tree.findByPreparePos(150);
    try testing.expectEqual(@as(u32, 150), cursor.effect_pos);
    try testing.expectEqual(@as(u32, 150), tree.rankOf(cursor.loc));

    const isolated = try tree.isolate(37);
    try testing.expectEqual(@as(Lv, 37), tree.item(isolated).lv);
    try testing.expectEqual(@as(u32, 37), tree.rankOf(isolated));

    tree.setCurState(isolated, -1);
    try testing.expectEqual(@as(u32, 199), tree.root.total().prepare);
    try testing.expectEqual(@as(u32, 200), tree.root.total().effect);

    tree.markDeleted(isolated);
    try testing.expectEqual(@as(u32, 199), tree.root.total().effect);
}

test "a long run splits into three around one byte" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();

    var loc = tree.start();
    var lv: Lv = 0;
    while (lv < 8) : (lv += 1) {
        loc = tree.nextLoc(try tree.insertAt(loc, .{ .lv = lv, .origin_left = if (lv == 0) none else lv - 1 }));
    }

    // Typing folded them into one run.
    try testing.expectEqual(@as(u32, 1), tree.root.total().items);

    const isolated = try tree.isolate(4);
    try testing.expectEqual(@as(u32, 1), tree.item(isolated).run_len);
    try testing.expectEqual(@as(u32, 3), tree.root.total().items);
    try testing.expectEqual(@as(u32, 8), tree.root.total().prepare);
}
