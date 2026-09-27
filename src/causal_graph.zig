const std = @import("std");
const agent = @import("agent.zig");

pub const Lv = u32;
pub const none: Lv = std.math.maxInt(Lv);

pub const Range = struct {
    start: Lv,
    end: Lv,

    pub fn len(self: Range) u32 {
        return self.end - self.start;
    }
};

pub const Entry = struct {
    lv: Lv,
    lv_end: Lv,
    agent: agent.Id,
    seq: agent.Seq,
    parents: []const Lv,

    pub fn seqEnd(self: Entry) agent.Seq {
        return self.seq + @as(agent.Seq, @intCast(self.lv_end - self.lv));
    }
};

const ClientEntry = struct {
    seq: agent.Seq,
    seq_end: agent.Seq,
    lv: Lv,
};

const Flag = enum { a, b, shared };

fn maxFirst(_: void, a: Lv, b: Lv) std.math.Order {
    return std.math.order(b, a);
}

const Queue = std.PriorityQueue(Lv, void, maxFirst);

/// Scratch space for diffs. A merge asks for one per event, so the queue and
/// the flags are kept and cleared instead of allocated every time.
pub const Workspace = struct {
    gpa: std.mem.Allocator,
    queue: Queue = .empty,
    flags: std.AutoHashMapUnmanaged(Lv, Flag) = .empty,
    a_only: std.ArrayList(Range) = .empty,
    b_only: std.ArrayList(Range) = .empty,

    pub fn init(gpa: std.mem.Allocator) Workspace {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Workspace) void {
        self.queue.deinit(self.gpa);
        self.flags.deinit(self.gpa);
        self.a_only.deinit(self.gpa);
        self.b_only.deinit(self.gpa);
    }

    fn reset(self: *Workspace) void {
        self.queue.clearRetainingCapacity();
        self.flags.clearRetainingCapacity();
        self.a_only.clearRetainingCapacity();
        self.b_only.clearRetainingCapacity();
    }
};

pub const CausalGraph = struct {
    entries: std.ArrayList(Entry) = .empty,
    heads: std.ArrayList(Lv) = .empty,
    by_agent: std.AutoHashMapUnmanaged(agent.Id, std.ArrayList(ClientEntry)) = .empty,
    // Versions that currently partition the graph: everything else is an
    // ancestor or a descendant of them. They form a chain, so they run-length
    // encode into very few ranges.
    criticals: std.ArrayList(Range) = .empty,

    pub fn deinit(self: *CausalGraph, gpa: std.mem.Allocator) void {
        for (self.entries.items) |entry| gpa.free(entry.parents);
        self.entries.deinit(gpa);
        self.heads.deinit(gpa);
        var it = self.by_agent.valueIterator();
        while (it.next()) |spans| spans.deinit(gpa);
        self.by_agent.deinit(gpa);
        self.criticals.deinit(gpa);
    }

    pub fn nextLv(self: CausalGraph) Lv {
        if (self.entries.items.len == 0) return 0;
        return self.entries.items[self.entries.items.len - 1].lv_end;
    }

    pub fn entryContaining(self: CausalGraph, lv: Lv) *const Entry {
        var low: usize = 0;
        var high: usize = self.entries.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = &self.entries.items[mid];
            if (lv < entry.lv) {
                high = mid;
            } else if (lv >= entry.lv_end) {
                low = mid + 1;
            } else {
                return entry;
            }
        }
        unreachable;
    }

    pub fn lvToRaw(self: CausalGraph, lv: Lv) agent.RawVersion {
        const entry = self.entryContaining(lv);
        return .{ .agent = entry.agent, .seq = entry.seq + @as(agent.Seq, @intCast(lv - entry.lv)) };
    }

    pub fn rawToLv(self: CausalGraph, raw: agent.RawVersion) ?Lv {
        const client = self.clientEntryContaining(raw.agent, raw.seq) orelse return null;
        return client.lv + (raw.seq - client.seq);
    }

    pub fn nextSeqForAgent(self: CausalGraph, id: agent.Id) agent.Seq {
        const spans = self.by_agent.get(id) orelse return 0;
        if (spans.items.len == 0) return 0;
        return spans.items[spans.items.len - 1].seq_end;
    }

    fn clientEntryContaining(self: CausalGraph, id: agent.Id, seq: agent.Seq) ?ClientEntry {
        const spans = self.by_agent.get(id) orelse return null;

        var low: usize = 0;
        var high: usize = spans.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const span = spans.items[mid];
            if (seq < span.seq) {
                high = mid;
            } else if (seq >= span.seq_end) {
                low = mid + 1;
            } else {
                return span;
            }
        }
        return null;
    }

    /// Returns null when every version in the span is already known.
    pub fn add(
        self: *CausalGraph,
        gpa: std.mem.Allocator,
        id: agent.Id,
        seq_start: agent.Seq,
        seq_end: agent.Seq,
        parents: []const Lv,
    ) !?Range {
        var seq = seq_start;
        var parent_buf: [1]Lv = undefined;
        var use = parents;

        while (self.clientEntryContaining(id, seq)) |existing| {
            if (existing.seq_end >= seq_end) return null;
            seq = existing.seq_end;
            parent_buf[0] = existing.lv + (existing.seq_end - existing.seq) - 1;
            use = parent_buf[0..1];
        }

        const lv = self.nextLv();
        const lv_end = lv + (seq_end - seq);
        const extends_everything = coversAll(self.heads.items, use);

        const owned = try gpa.dupe(Lv, use);
        const entry: Entry = .{ .lv = lv, .lv_end = lv_end, .agent = id, .seq = seq, .parents = owned };

        if (self.entries.items.len > 0 and tryAppendEntry(&self.entries.items[self.entries.items.len - 1], entry)) {
            gpa.free(owned);
        } else {
            try self.entries.append(gpa, entry);
        }

        try self.pushClientEntry(gpa, id, .{ .seq = seq, .seq_end = seq_end, .lv = lv });
        // Before the frontier moves, because `use` may alias it.
        try self.updateCriticals(gpa, .{ .start = lv, .end = lv_end }, use, extends_everything);
        try self.advanceFrontier(gpa, lv_end - 1, use);

        return .{ .start = lv, .end = lv_end };
    }

    fn updateCriticals(
        self: *CausalGraph,
        gpa: std.mem.Allocator,
        range: Range,
        parents: []const Lv,
        extends_everything: bool,
    ) !void {
        if (extends_everything) {
            if (self.criticals.items.len > 0) {
                const last = &self.criticals.items[self.criticals.items.len - 1];
                if (last.end == range.start) {
                    last.end = range.end;
                    return;
                }
            }
            try self.criticals.append(gpa, range);
            return;
        }

        // The new events branch off at their parents. A critical version at or
        // below the newest parent still has everything either before or after
        // it; anything above it is now concurrent with these events.
        var bound: Lv = 0;
        var branches = false;
        for (parents) |parent| bound = @max(bound, parent);
        if (parents.len == 0) branches = true;

        var kept = self.criticals.items.len;
        while (kept > 0) {
            const critical = self.criticals.items[kept - 1];
            if (!branches and critical.start <= bound) {
                self.criticals.items[kept - 1] = .{
                    .start = critical.start,
                    .end = @min(critical.end, bound + 1),
                };
                break;
            }
            kept -= 1;
        }
        self.criticals.shrinkRetainingCapacity(kept);
    }

    /// The most recent version at or before `lv` that partitions the graph.
    pub fn criticalAtOrBefore(self: CausalGraph, lv: Lv) ?Lv {
        var i = self.criticals.items.len;
        while (i > 0) {
            i -= 1;
            const critical = self.criticals.items[i];
            if (critical.start > lv) continue;
            return @min(critical.end - 1, lv);
        }
        return null;
    }

    pub fn isCritical(self: CausalGraph, lv: Lv) bool {
        var low: usize = 0;
        var high: usize = self.criticals.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const critical = self.criticals.items[mid];
            if (lv < critical.start) {
                high = mid;
            } else if (lv >= critical.end) {
                low = mid + 1;
            } else {
                return true;
            }
        }
        return false;
    }

    fn pushClientEntry(self: *CausalGraph, gpa: std.mem.Allocator, id: agent.Id, client: ClientEntry) !void {
        const gop = try self.by_agent.getOrPut(gpa, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const spans = gop.value_ptr;

        // The same agent can write to two branches, so seqs do not always arrive in order.
        var idx: usize = spans.items.len;
        while (idx > 0 and spans.items[idx - 1].seq > client.seq) idx -= 1;

        if (idx > 0) {
            const prev = &spans.items[idx - 1];
            if (prev.seq_end == client.seq and prev.lv + (prev.seq_end - prev.seq) == client.lv) {
                prev.seq_end = client.seq_end;
                return;
            }
        }
        try spans.insert(gpa, idx, client);
    }

    fn advanceFrontier(self: *CausalGraph, gpa: std.mem.Allocator, last: Lv, parents: []const Lv) !void {
        var kept: usize = 0;
        for (self.heads.items) |head| {
            if (std.mem.indexOfScalar(Lv, parents, head) != null) continue;
            self.heads.items[kept] = head;
            kept += 1;
        }
        self.heads.shrinkRetainingCapacity(kept);
        try self.heads.append(gpa, last);
        std.mem.sort(Lv, self.heads.items, {}, std.sort.asc(Lv));
    }

    /// Fills `ws.a_only` and `ws.b_only` with the events reachable from only
    /// one of the two versions.
    pub fn diff(self: CausalGraph, ws: *Workspace, a: []const Lv, b: []const Lv) !void {
        ws.reset();

        const gpa = ws.gpa;
        const flags = &ws.flags;
        const queue = &ws.queue;
        const a_only = &ws.a_only;
        const b_only = &ws.b_only;

        var shared: usize = 0;

        for (a) |v| try enqueue(gpa, queue, flags, &shared, v, .a);
        for (b) |v| try enqueue(gpa, queue, flags, &shared, v, .b);

        while (queue.count() > shared) {
            var v = queue.pop().?;
            var flag = flags.get(v).?;
            if (flag == .shared) shared -= 1;

            const entry = self.entryContaining(v);

            while (queue.peek()) |peeked| {
                if (peeked < entry.lv) break;
                const v2 = queue.pop().?;
                const flag2 = flags.get(v2).?;
                if (flag2 == .shared) shared -= 1;
                if (flag2 != flag) {
                    // v2 is already covered by the run we are about to mark, so the run starts above it.
                    try markRun(gpa, a_only, b_only, v2 + 1, v, flag);
                    v = v2;
                    flag = .shared;
                }
            }

            try markRun(gpa, a_only, b_only, entry.lv, v, flag);
            for (entry.parents) |p| try enqueue(gpa, queue, flags, &shared, p, flag);
        }

        std.mem.reverse(Range, a_only.items);
        std.mem.reverse(Range, b_only.items);
    }

    fn enqueue(
        gpa: std.mem.Allocator,
        queue: *Queue,
        flags: *std.AutoHashMapUnmanaged(Lv, Flag),
        shared: *usize,
        v: Lv,
        flag: Flag,
    ) !void {
        const gop = try flags.getOrPut(gpa, v);
        if (!gop.found_existing) {
            gop.value_ptr.* = flag;
            try queue.push(gpa, v);
            if (flag == .shared) shared.* += 1;
        } else if (gop.value_ptr.* != flag and gop.value_ptr.* != .shared) {
            gop.value_ptr.* = .shared;
            shared.* += 1;
        }
    }

    fn markRun(
        gpa: std.mem.Allocator,
        a_only: *std.ArrayList(Range),
        b_only: *std.ArrayList(Range),
        start: Lv,
        end_inclusive: Lv,
        flag: Flag,
    ) !void {
        if (flag == .shared) return;
        const target = if (flag == .a) a_only else b_only;
        const range: Range = .{ .start = start, .end = end_inclusive + 1 };
        if (target.items.len > 0) {
            const last = &target.items[target.items.len - 1];
            if (last.start == range.end) {
                last.start = range.start;
                return;
            }
        }
        try target.append(gpa, range);
    }

    pub fn findDominators(self: CausalGraph, gpa: std.mem.Allocator, versions: []const Lv) ![]Lv {
        if (versions.len <= 1) return gpa.dupe(Lv, versions);

        var result: std.ArrayList(Lv) = .empty;
        defer result.deinit(gpa);

        // Inputs are tagged by the low bit so ancestors sort below the input they came from.
        var queue: Queue = .empty;
        defer queue.deinit(gpa);

        for (versions) |v| try queue.push(gpa, v * 2);

        var remaining = versions.len;
        while (remaining > 0) {
            const encoded = queue.pop() orelse break;
            const v: Lv = encoded >> 1;
            if (encoded % 2 == 0) {
                try result.append(gpa, v);
                remaining -= 1;
            }

            const entry = self.entryContaining(v);

            while (queue.peek()) |peeked| {
                if (peeked < entry.lv * 2) break;
                const other = queue.pop().?;
                if (other % 2 == 0) remaining -= 1;
            }

            for (entry.parents) |p| try queue.push(gpa, p * 2 + 1);
        }

        std.mem.reverse(Lv, result.items);
        return result.toOwnedSlice(gpa);
    }

    pub fn lvOrder(self: CausalGraph, a: Lv, b: Lv) std.math.Order {
        return agent.RawVersion.order(self.lvToRaw(a), self.lvToRaw(b));
    }
};

fn coversAll(heads: []const Lv, parents: []const Lv) bool {
    for (heads) |head| {
        if (std.mem.indexOfScalar(Lv, parents, head) == null) return false;
    }
    return true;
}

fn tryAppendEntry(a: *Entry, b: Entry) bool {
    if (a.agent != b.agent) return false;
    if (a.lv_end != b.lv) return false;
    if (a.seqEnd() != b.seq) return false;
    if (b.parents.len != 1 or b.parents[0] != a.lv_end - 1) return false;
    a.lv_end = b.lv_end;
    return true;
}

const testing = std.testing;

fn expectRanges(expected: []const Range, actual: []const Range) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqual(e, a);
}

test "local edits from one agent collapse into a single entry" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 1, 0, 3, cg.heads.items);
    _ = try cg.add(testing.allocator, 1, 3, 5, cg.heads.items);

    try testing.expectEqual(@as(usize, 1), cg.entries.items.len);
    try testing.expectEqual(@as(Lv, 5), cg.nextLv());
    try testing.expectEqual(@as(usize, 1), cg.heads.items.len);
    try testing.expectEqual(@as(Lv, 4), cg.heads.items[0]);
}

test "raw versions round trip" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 7, 0, 4, cg.heads.items);
    _ = try cg.add(testing.allocator, 9, 0, 2, &.{1});

    try testing.expectEqual(agent.RawVersion{ .agent = 7, .seq = 2 }, cg.lvToRaw(2));
    try testing.expectEqual(@as(?Lv, 2), cg.rawToLv(.{ .agent = 7, .seq = 2 }));
    try testing.expectEqual(agent.RawVersion{ .agent = 9, .seq = 1 }, cg.lvToRaw(5));
    try testing.expectEqual(@as(?Lv, null), cg.rawToLv(.{ .agent = 9, .seq = 9 }));
}

test "adding a known span twice is a no-op" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 1, 0, 3, &.{});
    const again = try cg.add(testing.allocator, 1, 0, 3, &.{});

    try testing.expectEqual(@as(?Range, null), again);
    try testing.expectEqual(@as(Lv, 3), cg.nextLv());
}

test "overlapping spans are trimmed to the new part" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 1, 0, 2, &.{});
    const added = (try cg.add(testing.allocator, 1, 0, 5, &.{})).?;

    try testing.expectEqual(Range{ .start = 2, .end = 5 }, added);
    try testing.expectEqual(agent.RawVersion{ .agent = 1, .seq = 4 }, cg.lvToRaw(4));
}

test "diff separates the two sides of a fork" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    // a0 <- b0,b1 (agent 2) and a0 <- c0 (agent 3)
    _ = try cg.add(testing.allocator, 1, 0, 1, &.{});
    const left = (try cg.add(testing.allocator, 2, 0, 2, &.{0})).?;
    const right = (try cg.add(testing.allocator, 3, 0, 1, &.{0})).?;

    var ws: Workspace = .init(testing.allocator);
    defer ws.deinit();

    try cg.diff(&ws, &.{left.end - 1}, &.{right.end - 1});

    try expectRanges(&.{.{ .start = 1, .end = 3 }}, ws.a_only.items);
    try expectRanges(&.{.{ .start = 3, .end = 4 }}, ws.b_only.items);
}

test "diff of a version against its ancestor is one sided" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 1, 0, 4, cg.heads.items);

    var ws: Workspace = .init(testing.allocator);
    defer ws.deinit();

    try cg.diff(&ws, &.{3}, &.{1});

    try expectRanges(&.{.{ .start = 2, .end = 4 }}, ws.a_only.items);
    try expectRanges(&.{}, ws.b_only.items);
}

test "dominators drop versions covered by others" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 1, 0, 3, cg.heads.items);
    _ = try cg.add(testing.allocator, 2, 0, 1, &.{0});

    const dominators = try cg.findDominators(testing.allocator, &.{ 0, 1, 2, 3 });
    defer testing.allocator.free(dominators);

    try testing.expectEqualSlices(Lv, &.{ 2, 3 }, dominators);
}

test "linear history is critical all the way" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 1, 0, 3, cg.heads.items);
    _ = try cg.add(testing.allocator, 2, 0, 2, cg.heads.items);

    try testing.expectEqual(@as(usize, 1), cg.criticals.items.len);
    try testing.expectEqual(Range{ .start = 0, .end = 5 }, cg.criticals.items[0]);
    try testing.expectEqual(@as(?Lv, 3), cg.criticalAtOrBefore(3));
}

test "a fork drops criticality back to the branch point" {
    var cg: CausalGraph = .{};
    defer cg.deinit(testing.allocator);

    _ = try cg.add(testing.allocator, 1, 0, 2, &.{});
    _ = try cg.add(testing.allocator, 2, 0, 1, &.{1});
    // Branches off lv 1, so lv 2 is no longer a partition of the graph.
    _ = try cg.add(testing.allocator, 3, 0, 1, &.{1});

    try testing.expect(cg.isCritical(1));
    try testing.expect(!cg.isCritical(2));
    try testing.expect(!cg.isCritical(3));
    try testing.expectEqual(@as(?Lv, 1), cg.criticalAtOrBefore(3));

    // Merging both branches makes the merge point critical again.
    _ = try cg.add(testing.allocator, 1, 2, 3, &.{ 2, 3 });
    try testing.expect(cg.isCritical(4));
    try testing.expectEqual(@as(?Lv, 4), cg.criticalAtOrBefore(4));
}
