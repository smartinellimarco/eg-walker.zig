const std = @import("std");

const fanout = 16;
const chunk = 256;

/// A rope over UTF-8 chunks. Positions are character offsets, so every node
/// counts both characters and bytes: edits land in logarithmic time no matter
/// how far apart they are, and the text comes back out without re-encoding.
pub const Text = struct {
    gpa: std.mem.Allocator,
    // Chunks come from an arena and go away together.
    arena: std.heap.ArenaAllocator,
    root: *Node,
    // The chunk the last edit landed in, and the position of its first
    // character. Edits cluster, so the next one usually falls inside it and
    // skips the descent.
    cursor_leaf: ?*Node = null,
    cursor_leaf_pos: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) !Text {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const root = try newNode(arena.allocator(), 0);

        return .{ .gpa = gpa, .arena = arena, .root = root };
    }

    pub fn deinit(self: *Text) void {
        self.arena.deinit();
    }

    pub fn len(self: Text) u32 {
        return self.root.total().chars;
    }

    pub fn insertUtf8(self: *Text, pos: u32, text: []const u8) !void {
        const found = self.find(pos);
        var leaf = found.leaf;
        var offset = found.offset;
        var rest = text;

        while (rest.len > 0) {
            var take = fitting(rest, chunk - leaf.bytes);
            if (take == 0) {
                // No room here: push the tail of this chunk into a new one, and
                // if even that leaves too little, start a fresh chunk.
                if (offset < leaf.bytes) {
                    try self.splitLeaf(leaf, offset);
                    take = fitting(rest, chunk - leaf.bytes);
                }
                if (take == 0) {
                    const sibling = try newNode(self.arena.allocator(), 0);
                    try self.insertChild(leaf, sibling);
                    leaf = sibling;
                    offset = 0;
                    take = fitting(rest, chunk);
                }
            }

            leaf.moveGap(@intCast(offset));
            @memcpy(leaf.text[leaf.gap_start..][0..take], rest[0..take]);
            leaf.gap_start += @intCast(take);

            const added = charsIn(rest[0..take]);
            leaf.bytes += @intCast(take);
            leaf.chars += @intCast(added);

            self.fixCounts(leaf, added, @intCast(take));

            offset += take;
            rest = rest[take..];
        }
    }

    pub fn delete(self: *Text, pos: u32, count: u32) void {
        const found = self.find(pos);
        var leaf = found.leaf;
        var offset = found.offset;
        var remaining = count;

        while (remaining > 0) {
            leaf.moveGap(@intCast(offset));
            const after = leaf.tail();
            const take = bytesOf(after, remaining);

            if (take > 0) {
                const removed = charsIn(after[0..take]);
                leaf.gap_end += @intCast(take);
                leaf.bytes -= @intCast(take);
                leaf.chars -= @intCast(removed);

                self.fixCounts(leaf, -@as(i64, removed), -@as(i64, take));
                remaining -= removed;
            }

            if (remaining == 0) break;
            leaf = nextLeaf(leaf) orelse break;
            offset = 0;
        }
    }

    pub fn toUtf8(self: Text, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, self.root.total().bytes);

        var leaf: ?*Node = firstLeaf(self.root);
        while (leaf) |node| : (leaf = nextLeaf(node)) {
            out.appendSliceAssumeCapacity(node.head());
            out.appendSliceAssumeCapacity(node.tail());
        }

        return out.toOwnedSlice(gpa);
    }

    const Position = struct {
        leaf: *Node,
        offset: u32,
    };

    fn find(self: *Text, pos: u32) Position {
        var node = self.root;
        var base: u32 = 0;

        // Climb out of the last chunk only as far as the position needs, which
        // for nearby edits is not at all.
        if (self.cursor_leaf) |leaf| {
            var walk = leaf;
            var walk_base = self.cursor_leaf_pos;
            while (true) {
                if (pos >= walk_base and pos - walk_base <= walk.total().chars) {
                    node = walk;
                    base = walk_base;
                    break;
                }

                const parent = walk.parent orelse break;
                for (parent.counts[0..walk.parent_idx]) |child| walk_base -= child.chars;
                walk = parent;
            }
        }

        const walked = descend(node, pos - base);

        self.cursor_leaf = walked.leaf;
        self.cursor_leaf_pos = pos - walked.remaining;

        return .{ .leaf = walked.leaf, .offset = offsetIn(walked.leaf, walked.remaining) };
    }

    /// Copies the characters in [from, to). Takes a const pointer on purpose:
    /// reading must not move a gap or the cached chunk, or every render would
    /// cost the next edit its head start.
    pub fn slice(self: *const Text, gpa: std.mem.Allocator, from: u32, to: u32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, to - from);

        const walked = descend(self.root, from);
        var skip = offsetIn(walked.leaf, walked.remaining);
        var remaining = to - from;

        var leaf: ?*Node = walked.leaf;
        while (leaf) |node| : (leaf = nextLeaf(node)) {
            if (remaining == 0) break;

            // The gap splits a chunk in two, and neither half is moved to read.
            for ([_][]u8{ node.head(), node.tail() }) |piece| {
                if (skip >= piece.len) {
                    skip -= @intCast(piece.len);
                    continue;
                }

                const rest = piece[skip..];
                skip = 0;

                const take = bytesOf(rest, remaining);
                out.appendSliceAssumeCapacity(rest[0..take]);
                remaining -= charsIn(rest[0..take]);
                if (remaining == 0) break;
            }
        }

        return out.toOwnedSlice(gpa);
    }

    fn fixCounts(self: *Text, leaf: *Node, chars: i64, bytes: i64) void {
        _ = self;
        var node = leaf;
        while (node.parent) |parent| {
            const slot = &parent.counts[node.parent_idx];
            slot.chars = @intCast(@as(i64, slot.chars) + chars);
            slot.bytes = @intCast(@as(i64, slot.bytes) + bytes);

            parent.subtree.chars = @intCast(@as(i64, parent.subtree.chars) + chars);
            parent.subtree.bytes = @intCast(@as(i64, parent.subtree.bytes) + bytes);

            node = parent;
        }
    }

    fn splitLeaf(self: *Text, leaf: *Node, offset: u32) !void {
        self.cursor_leaf = null;
        const sibling = try newNode(self.arena.allocator(), 0);

        leaf.moveGap(@intCast(offset));
        const moved: u16 = @intCast(leaf.tail().len);

        @memcpy(sibling.text[0..moved], leaf.tail());
        const moved_chars = charsIn(sibling.text[0..moved]);
        sibling.bytes = moved;
        sibling.chars = @intCast(moved_chars);
        sibling.gap_start = moved;
        sibling.gap_end = chunk;

        leaf.gap_end = chunk;
        leaf.bytes -= moved;
        leaf.chars -= @intCast(moved_chars);

        // Only this leaf's own entry moves: the text stayed in the subtree.
        if (leaf.parent) |parent| {
            parent.counts[leaf.parent_idx] = leaf.total();
            parent.recount();
        }
        try self.insertChild(leaf, sibling);
    }

    fn insertChild(self: *Text, after: *Node, child: *Node) std.mem.Allocator.Error!void {
        if (after.parent == null) {
            const root = try newNode(self.arena.allocator(), after.level + 1);
            root.len = 1;
            root.children[0] = after;
            root.counts[0] = after.total();
            root.recount();
            after.parent = root;
            after.parent_idx = 0;
            self.root = root;
        }

        if (after.parent.?.len == fanout) try self.splitNode(after.parent.?);

        const parent = after.parent.?;
        const at = after.parent_idx + 1;

        var i = parent.len;
        while (i > at) : (i -= 1) {
            parent.children[i] = parent.children[i - 1];
            parent.counts[i] = parent.counts[i - 1];
            parent.children[i].parent_idx = i;
        }

        parent.children[at] = child;
        parent.counts[at] = child.total();
        parent.len += 1;
        parent.recount();

        child.parent = parent;
        child.parent_idx = at;

        var walk = parent;
        while (walk.parent) |grandparent| {
            grandparent.counts[walk.parent_idx] = walk.total();
            grandparent.recount();
            walk = grandparent;
        }
    }

    fn splitNode(self: *Text, node: *Node) std.mem.Allocator.Error!void {
        const sibling = try newNode(self.arena.allocator(), node.level);
        const keep = node.len / 2;
        const moved = node.len - keep;

        @memcpy(sibling.counts[0..moved], node.counts[keep..node.len]);
        @memcpy(sibling.children[0..moved], node.children[keep..node.len]);
        sibling.len = moved;
        node.len = keep;
        sibling.recount();
        node.recount();

        for (sibling.children[0..moved], 0..) |child, i| {
            child.parent = sibling;
            child.parent_idx = @intCast(i);
        }

        if (node.parent) |parent| parent.counts[node.parent_idx] = node.total();
        try self.insertChild(node, sibling);
    }
};

const Counts = struct {
    chars: u32 = 0,
    bytes: u32 = 0,

    fn add(self: *Counts, other: Counts) void {
        self.chars += other.chars;
        self.bytes += other.bytes;
    }
};

const Node = struct {
    parent: ?*Node = null,
    parent_idx: u16 = 0,
    level: u8,
    len: u16 = 0,
    bytes: u16 = 0,
    // Kept so a position never has to be counted out byte by byte, and so
    // plain ascii chunks can map positions straight to offsets.
    chars: u16 = 0,
    // Free space inside the chunk, parked where the last edit landed so that
    // typing forwards never moves anything.
    gap_start: u16 = 0,
    gap_end: u16 = chunk,
    counts: [fanout]Counts = @splat(.{}),
    // What the whole subtree holds, so climbing out of a chunk costs nothing.
    subtree: Counts = .{},
    text: [chunk]u8 = undefined,
    children: [fanout]*Node = undefined,

    fn moveGap(self: *Node, offset: u16) void {
        if (offset < self.gap_start) {
            const count = self.gap_start - offset;
            std.mem.copyBackwards(u8, self.text[self.gap_end - count ..][0..count], self.text[offset..][0..count]);
            self.gap_start -= count;
            self.gap_end -= count;
        } else if (offset > self.gap_start) {
            const count = offset - self.gap_start;
            std.mem.copyForwards(u8, self.text[self.gap_start..][0..count], self.text[self.gap_end..][0..count]);
            self.gap_start += count;
            self.gap_end += count;
        }
    }

    fn head(self: *Node) []u8 {
        return self.text[0..self.gap_start];
    }

    fn tail(self: *Node) []u8 {
        return self.text[self.gap_end..];
    }

    fn total(self: Node) Counts {
        return if (self.level == 0) .{ .chars = self.chars, .bytes = self.bytes } else self.subtree;
    }

    fn recount(self: *Node) void {
        self.subtree = .{};
        for (self.counts[0..self.len]) |child| self.subtree.add(child);
    }
};

fn charsIn(text: []const u8) u32 {
    var count: u32 = 0;
    for (text) |byte| count += @intFromBool(byte & 0xc0 != 0x80);
    return count;
}

/// Byte offset of the character at `count`.
fn bytesOf(text: []const u8, count: u32) u32 {
    var seen: u32 = 0;
    var at: u32 = 0;
    while (at < text.len) : (at += 1) {
        if (text[at] & 0xc0 == 0x80) continue;
        if (seen == count) return at;
        seen += 1;
    }
    return @intCast(text.len);
}

/// How many bytes of `text` fit in `room` without splitting a character.
fn fitting(text: []const u8, room: u32) u32 {
    if (text.len <= room) return @intCast(text.len);

    var at = room;
    while (at > 0 and text[at] & 0xc0 == 0x80) at -= 1;
    return at;
}

fn descend(from: *Node, remaining: u32) struct { leaf: *Node, remaining: u32 } {
    var node = from;
    var left = remaining;

    while (node.level > 0) {
        var child: u16 = 0;
        while (child + 1 < node.len and left > node.counts[child].chars) : (child += 1) {
            left -= node.counts[child].chars;
        }
        node = node.children[child];
    }

    return .{ .leaf = node, .remaining = left };
}

/// Byte offset of the character at `remaining` inside a chunk, gap included.
fn offsetIn(leaf: *Node, remaining: u32) u32 {
    // An ascii chunk needs no counting: the offset is the position.
    if (leaf.chars == leaf.bytes) return remaining;

    const in_head = charsIn(leaf.head());
    if (remaining <= in_head) return bytesOf(leaf.head(), remaining);
    return @as(u32, leaf.gap_start) + bytesOf(leaf.tail(), remaining - in_head);
}

fn firstLeaf(node: *Node) *Node {
    var walk = node;
    while (walk.level > 0) walk = walk.children[0];
    return walk;
}

fn nextLeaf(leaf: *Node) ?*Node {
    var node = leaf;
    while (node.parent) |parent| {
        if (node.parent_idx + 1 < parent.len) return firstLeaf(parent.children[node.parent_idx + 1]);
        node = parent;
    }
    return null;
}

fn newNode(gpa: std.mem.Allocator, level: u8) !*Node {
    const node = try gpa.create(Node);
    node.* = .{ .level = level };
    return node;
}

fn checkNode(node: *Node) !Counts {
    if (node.level == 0) {
        try std.testing.expectEqual(@as(u32, node.chars), charsIn(node.head()) + charsIn(node.tail()));
        try std.testing.expectEqual(@as(u32, node.bytes), @as(u32, @intCast(node.head().len + node.tail().len)));
        return .{ .chars = node.chars, .bytes = node.bytes };
    }

    var sum: Counts = .{};
    try std.testing.expectEqual(node.subtree, node.total());
    for (node.children[0..node.len], 0..) |child, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i)), child.parent_idx);
        try std.testing.expect(child.parent == node);

        const actual = try checkNode(child);
        try std.testing.expectEqual(node.counts[i], actual);
        sum.add(actual);
    }
    return sum;
}

const testing = std.testing;

test "counts stay consistent while the tree grows" {
    const gpa = testing.allocator;

    var text = try Text.init(gpa);
    defer text.deinit();

    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();

    for (0..40000) |step| {
        const length = text.len();
        const pos = if (length == 0) 0 else random.uintAtMost(u32, length);

        var what: []const u8 = "insert";
        var amount: u32 = 0;
        if (length > 4000 and random.boolean()) {
            amount = @min(random.uintAtMost(u32, 30) + 1, length - pos);
            what = "delete";
            text.delete(pos, amount);
        } else {
            const word = "lorem ipsum "[0 .. random.uintAtMost(usize, 11) + 1];
            amount = @intCast(word.len);
            try text.insertUtf8(pos, word);
        }

        _ = checkNode(text.root) catch |err| {
            std.debug.print("broken after step {d}: {s} pos {d} amount {d} of {d}\n", .{ step, what, pos, amount, length });
            return err;
        };
    }
}

test "edits near and far from each other" {
    var text = try Text.init(testing.allocator);
    defer text.deinit();

    try text.insertUtf8(0, "hola");
    try text.insertUtf8(4, " q");
    try text.insertUtf8(0, "¿");
    text.delete(5, 2);

    const out = try text.toUtf8(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("¿hola", out);
    try testing.expectEqual(@as(u32, 5), text.len());
}

test "grows past a chunk without losing either side" {
    var text = try Text.init(testing.allocator);
    defer text.deinit();

    var i: u32 = 0;
    while (i < 500) : (i += 1) try text.insertUtf8(0, "a");
    while (i > 0) : (i -= 1) try text.insertUtf8(text.len(), "b");

    try testing.expectEqual(@as(u32, 1000), text.len());

    const out = try text.toUtf8(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 1000), out.len);
    try testing.expectEqual(@as(u8, 'a'), out[499]);
    try testing.expectEqual(@as(u8, 'b'), out[500]);
}

test "multi byte characters are never split" {
    var text = try Text.init(testing.allocator);
    defer text.deinit();

    var i: u32 = 0;
    while (i < 400) : (i += 1) try text.insertUtf8(text.len(), "áé→");

    try testing.expectEqual(@as(u32, 1200), text.len());

    const out = try text.toUtf8(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1200), try std.unicode.utf8CountCodepoints(out));

    text.delete(1, 1198);

    const trimmed = try text.toUtf8(testing.allocator);
    defer testing.allocator.free(trimmed);
    try testing.expectEqualStrings("á→", trimmed);
}

test "random edits match a plain buffer" {
    const gpa = testing.allocator;

    var text = try Text.init(gpa);
    defer text.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);

    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();

    for (0..3000) |_| {
        const length: u32 = @intCast(model.items.len);
        const pos = if (length == 0) 0 else random.uintAtMost(u32, length);

        if (length > 0 and pos < length and random.boolean()) {
            const count = @min(random.uintAtMost(u32, 8) + 1, length - pos);
            text.delete(pos, count);
            model.replaceRangeAssumeCapacity(pos, count, &.{});
        } else {
            const word = "abcdef";
            const take = random.uintAtMost(usize, word.len - 1) + 1;
            try text.insertUtf8(pos, word[0..take]);
            try model.insertSlice(gpa, pos, word[0..take]);
        }
    }

    const out = try text.toUtf8(gpa);
    defer gpa.free(out);
    try testing.expectEqualStrings(model.items, out);
}

test "a chunk that fills exactly takes the next character" {
    var text = try Text.init(testing.allocator);
    defer text.deinit();

    const filler: [chunk]u8 = @splat('a');
    try text.insertUtf8(0, &filler);
    try text.insertUtf8(chunk, "b");
    try text.insertUtf8(chunk, "c");

    const out = try text.toUtf8(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, chunk + 2), out.len);
    try testing.expectEqualStrings("acb", out[chunk - 1 ..]);
}

test "a character too wide for what is left starts a new chunk" {
    var text = try Text.init(testing.allocator);
    defer text.deinit();

    const filler: [chunk - 2]u8 = @splat('a');
    try text.insertUtf8(0, &filler);
    try text.insertUtf8(chunk - 2, "→");
    try text.insertUtf8(chunk - 1, "→");

    const out = try text.toUtf8(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(u32, chunk), text.len());
    try testing.expectEqualStrings("a→→", out[chunk - 3 ..]);
}

test "the chunk cursor keeps pointing where it says" {
    const gpa = testing.allocator;

    var text = try Text.init(gpa);
    defer text.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);

    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();

    for (0..2000) |_| {
        const length: u32 = @intCast(model.items.len);
        const pos = if (length == 0) 0 else random.uintAtMost(u32, length);

        if (length > 2000 and random.boolean()) {
            const count = @min(random.uintAtMost(u32, 600) + 1, length - pos);
            text.delete(pos, count);
            model.replaceRangeAssumeCapacity(pos, count, &.{});
        } else {
            const word = "lorem ipsum "[0 .. random.uintAtMost(usize, 11) + 1];
            try text.insertUtf8(pos, word);
            try model.insertSlice(gpa, pos, word);
        }

        if (text.cursor_leaf) |leaf| try testing.expectEqual(text.cursor_leaf_pos, cursorBase(leaf));

        const out = try text.toUtf8(gpa);
        defer gpa.free(out);
        try testing.expectEqualStrings(model.items, out);
    }
}

fn cursorBase(leaf: *Node) u32 {
    var node = leaf;
    var base: u32 = 0;
    while (node.parent) |parent| {
        for (parent.counts[0..node.parent_idx]) |child| base += child.chars;
        node = parent;
    }
    return base;
}

test "a jump backwards lands where a plain descent would" {
    const gpa = testing.allocator;

    // The shape of a recorded editing session, reduced: jumps of thousands of
    // characters between chunks, a delete that spans several, and a reinsert of
    // the same size. Only positions and lengths are kept, the text is filler.
    const ops = [_]struct { insert: bool, pos: u32, len: u32 }{
        .{ .insert = true, .pos = 0, .len = 6003 },
        .{ .insert = true, .pos = 0, .len = 1 },
        .{ .insert = true, .pos = 9, .len = 16 },
        .{ .insert = false, .pos = 9, .len = 16 },
        .{ .insert = true, .pos = 3025, .len = 13 },
        .{ .insert = false, .pos = 3032, .len = 6 },
        .{ .insert = true, .pos = 438, .len = 11 },
        .{ .insert = true, .pos = 851, .len = 2 },
        .{ .insert = true, .pos = 941, .len = 53 },
        .{ .insert = true, .pos = 941, .len = 34 },
        .{ .insert = false, .pos = 910, .len = 2 },
        .{ .insert = true, .pos = 3003, .len = 4 },
        .{ .insert = true, .pos = 2134, .len = 3 },
        .{ .insert = true, .pos = 2136, .len = 23 },
        .{ .insert = true, .pos = 4228, .len = 3 },
        .{ .insert = true, .pos = 4221, .len = 3 },
        .{ .insert = true, .pos = 4083, .len = 3 },
        .{ .insert = true, .pos = 4034, .len = 3 },
        .{ .insert = true, .pos = 4001, .len = 3 },
        .{ .insert = true, .pos = 3869, .len = 3 },
        .{ .insert = true, .pos = 3606, .len = 3 },
        .{ .insert = true, .pos = 2186, .len = 12 },
        .{ .insert = true, .pos = 2190, .len = 56 },
        .{ .insert = true, .pos = 2273, .len = 79 },
        .{ .insert = true, .pos = 1819, .len = 49 },
        .{ .insert = true, .pos = 2880, .len = 11 },
        .{ .insert = true, .pos = 2863, .len = 3 },
        .{ .insert = true, .pos = 2577, .len = 69 },
        .{ .insert = false, .pos = 2505, .len = 578 },
        .{ .insert = true, .pos = 2908, .len = 578 },
        .{ .insert = true, .pos = 3090, .len = 31 },
        .{ .insert = true, .pos = 4552, .len = 4 },
        .{ .insert = true, .pos = 3859, .len = 4 },
    };

    var text = try Text.init(gpa);
    defer text.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);

    const scratch = try gpa.alloc(u8, 6003);
    defer gpa.free(scratch);

    for (ops, 0..) |op, step| {
        if (op.insert) {
            const written = scratch[0..op.len];
            for (written, 0..) |*byte, at| byte.* = 'a' + @as(u8, @intCast((step * 7 + at) % 26));
            try text.insertUtf8(op.pos, written);
            try model.insertSlice(gpa, op.pos, written);
        } else {
            text.delete(op.pos, op.len);
            model.replaceRangeAssumeCapacity(op.pos, op.len, &.{});
        }

        const out = try text.toUtf8(gpa);
        defer gpa.free(out);
        try testing.expectEqualStrings(model.items, out);
    }
}

test "a slice reads back a range of characters" {
    const gpa = testing.allocator;

    var text = try Text.init(gpa);
    defer text.deinit();
    try text.insertUtf8(0, "hello world");

    const middle = try text.slice(gpa, 6, 11);
    defer gpa.free(middle);
    try testing.expectEqualStrings("world", middle);

    const whole = try text.slice(gpa, 0, text.len());
    defer gpa.free(whole);
    try testing.expectEqualStrings("hello world", whole);

    const empty = try text.slice(gpa, 4, 4);
    defer gpa.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "a slice cuts between characters, never inside one" {
    const gpa = testing.allocator;

    var text = try Text.init(gpa);
    defer text.deinit();
    try text.insertUtf8(0, "áéíóú→");

    const cut = try text.slice(gpa, 2, 5);
    defer gpa.free(cut);
    try testing.expectEqualStrings("íóú", cut);

    const arrow = try text.slice(gpa, 5, 6);
    defer gpa.free(arrow);
    try testing.expectEqualStrings("→", arrow);
}

test "a slice spans chunks and gaps" {
    const gpa = testing.allocator;

    var text = try Text.init(gpa);
    defer text.deinit();

    var i: u32 = 0;
    while (i < 500) : (i += 1) try text.insertUtf8(text.len(), "abcdefghij");

    // Edits in the middle leave gaps parked in the chunks they touched.
    text.delete(1200, 100);
    try text.insertUtf8(800, "ZZZ");

    const model = try text.toUtf8(gpa);
    defer gpa.free(model);

    const part = try text.slice(gpa, 700, 1500);
    defer gpa.free(part);
    try testing.expectEqualStrings(model[700..1500], part);
}

test "reading does not move the cached chunk" {
    const gpa = testing.allocator;

    var text = try Text.init(gpa);
    defer text.deinit();

    var i: u32 = 0;
    while (i < 200) : (i += 1) try text.insertUtf8(text.len(), "abcdefghij");

    const at_the_end = text.cursor_leaf_pos;

    const far = try text.slice(gpa, 0, 50);
    defer gpa.free(far);

    try testing.expectEqual(at_the_end, text.cursor_leaf_pos);
}
