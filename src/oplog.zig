const std = @import("std");
const agent = @import("agent.zig");
const causal_graph = @import("causal_graph.zig");
const sync = @import("encoding/sync.zig");
const wire = @import("encoding/wire.zig");

const Lv = causal_graph.Lv;

pub const OpKind = enum { insert, delete };

pub const Op = struct {
    kind: OpKind,
    pos: u32,
    content: []const u8 = "",
};

pub const Run = struct {
    lv: Lv,
    len: u32,
    kind: OpKind,
    pos: u32,
    // Typing and forward deletes run one way, backspace the other.
    fwd: bool,
    // Where the inserted text starts, stored as UTF-8 so a patch is a copy rather
    // than a re-encoding.
    content_start: u32,

    pub fn lvEnd(self: Run) Lv {
        return self.lv + self.len;
    }

    pub fn posAt(self: Run, offset: u32) u32 {
        return switch (self.kind) {
            .insert => self.pos + offset,
            .delete => if (self.fwd) self.pos else self.pos - offset,
        };
    }

    fn tryAppend(a: *Run, b: Run) bool {
        if (a.kind != b.kind) return false;
        if (a.lvEnd() != b.lv) return false;
        switch (a.kind) {
            .insert => {
                if (!a.fwd or !b.fwd) return false;
                if (b.pos != a.pos + a.len) return false;
                if (b.content_start != a.content_start + a.len) return false;
            },
            // A run of one event has not committed to a direction yet, so it can
            // still turn out to be the start of a backspace run. A longer run
            // has, and the new events have to agree with it.
            .delete => {
                const forward = (a.len == 1 or a.fwd) and (b.len == 1 or b.fwd) and b.pos == a.pos;
                const backward = (a.len == 1 or !a.fwd) and (b.len == 1 or !b.fwd) and
                    a.pos >= a.len and b.pos == a.pos - a.len;

                if (forward) {
                    a.fwd = true;
                } else if (backward) {
                    a.fwd = false;
                } else return false;
            },
        }

        a.len += b.len;
        return true;
    }
};

pub const Options = struct {
    agent: agent.Id,
};

pub const OpLog = struct {
    gpa: std.mem.Allocator,
    agent: agent.Id,
    cg: causal_graph.CausalGraph = .{},
    runs: std.ArrayList(Run) = .empty,
    content: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, options: Options) OpLog {
        return .{ .gpa = gpa, .agent = options.agent };
    }

    pub fn deinit(self: *OpLog) void {
        self.cg.deinit(self.gpa);
        self.runs.deinit(self.gpa);
        self.content.deinit(self.gpa);
    }

    pub fn len(self: OpLog) Lv {
        return self.cg.nextLv();
    }

    pub fn version(self: OpLog) []const Lv {
        return self.cg.heads.items;
    }

    pub fn insert(self: *OpLog, pos: u32, text: []const u8) !void {
        _ = try self.insertAt(self.agent, self.cg.heads.items, pos, text);
    }

    pub fn delete(self: *OpLog, pos: u32, count: u32) !void {
        _ = try self.deleteAt(self.agent, self.cg.heads.items, pos, count, true);
    }

    pub fn backspace(self: *OpLog, pos: u32, count: u32) !void {
        _ = try self.deleteAt(self.agent, self.cg.heads.items, pos, count, false);
    }

    /// Records an edit made by `id` on top of an arbitrary version, which is
    /// what replaying a recorded session or an explicit branch needs.
    pub fn insertAt(self: *OpLog, id: agent.Id, parents: []const Lv, pos: u32, text: []const u8) !causal_graph.Range {
        const count: u32 = @intCast(text.len);
        if (count == 0) return .{ .start = self.len(), .end = self.len() };

        const content_start: u32 = @intCast(self.content.items.len);
        try self.content.appendSlice(self.gpa, text);

        const seq = self.cg.nextSeqForAgent(id);
        const range = (try self.cg.add(self.gpa, id, seq, seq + count, parents)).?;
        try self.pushRun(.{
            .lv = range.start,
            .len = count,
            .kind = .insert,
            .pos = pos,
            .fwd = true,
            .content_start = content_start,
        });
        return range;
    }

    pub fn deleteAt(self: *OpLog, id: agent.Id, parents: []const Lv, pos: u32, count: u32, fwd: bool) !causal_graph.Range {
        if (count == 0) return .{ .start = self.len(), .end = self.len() };

        const seq = self.cg.nextSeqForAgent(id);
        const range = (try self.cg.add(self.gpa, id, seq, seq + count, parents)).?;
        try self.pushRun(.{
            .lv = range.start,
            .len = count,
            .kind = .delete,
            .pos = pos,
            .fwd = fwd,
            .content_start = 0,
        });
        return range;
    }

    fn pushRun(self: *OpLog, run: Run) !void {
        if (self.runs.items.len > 0 and Run.tryAppend(&self.runs.items[self.runs.items.len - 1], run)) return;
        try self.runs.append(self.gpa, run);
    }

    /// Index of the run holding `lv`. Callers that walk forwards keep the index
    /// instead of searching again for every run.
    pub fn runIndexContaining(self: OpLog, lv: Lv) usize {
        var low: usize = 0;
        var high: usize = self.runs.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const run = &self.runs.items[mid];
            if (lv < run.lv) {
                high = mid;
            } else if (lv >= run.lvEnd()) {
                low = mid + 1;
            } else {
                return mid;
            }
        }
        unreachable;
    }

    pub fn runAt(self: OpLog, index: usize) *const Run {
        return &self.runs.items[index];
    }

    pub fn runContaining(self: OpLog, lv: Lv) *const Run {
        var low: usize = 0;
        var high: usize = self.runs.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const run = &self.runs.items[mid];
            if (lv < run.lv) {
                high = mid;
            } else if (lv >= run.lvEnd()) {
                low = mid + 1;
            } else {
                return run;
            }
        }
        unreachable;
    }

    /// The single event at `lv`, which the tests and remote merges read back.
    pub fn opAt(self: OpLog, lv: Lv) Op {
        const run = self.runContaining(lv);
        const offset = lv - run.lv;
        return .{
            .kind = run.kind,
            .pos = run.posAt(offset),
            .content = if (run.kind == .insert) self.contentOf(run.*, offset, 1) else "",
        };
    }

    pub fn kindAt(self: OpLog, lv: Lv) OpKind {
        return self.runContaining(lv).kind;
    }

    /// The inserted text of `count` bytes of `run`, starting `offset` bytes in.
    pub fn contentOf(self: OpLog, run: Run, offset: u32, count: u32) []const u8 {
        return self.content.items[run.content_start + offset ..][0..count];
    }

    /// Adds events received from another replica at already assigned local
    /// versions.
    pub fn pushRemote(self: *OpLog, lv: Lv, count: u32, kind: OpKind, pos: u32, fwd: bool, text: []const u8) !void {
        var content_start: u32 = 0;
        if (kind == .insert) {
            content_start = @intCast(self.content.items.len);
            try self.content.appendSlice(self.gpa, text);
        }

        try self.pushRun(.{
            .lv = lv,
            .len = count,
            .kind = kind,
            .pos = pos,
            .fwd = fwd,
            .content_start = content_start,
        });
    }

    pub fn versionSummary(self: OpLog, gpa: std.mem.Allocator) !sync.VersionSummary {
        return sync.summarize(gpa, self.cg);
    }

    /// The local version ranges another replica is missing.
    pub fn rangesMissing(self: OpLog, gpa: std.mem.Allocator, theirs: sync.VersionSummary) ![]causal_graph.Range {
        return sync.rangesMissing(gpa, self.cg, theirs);
    }

    pub fn serialize(self: OpLog, gpa: std.mem.Allocator, ranges: []const causal_graph.Range) ![]u8 {
        return wire.encode(gpa, &self, ranges);
    }

    pub fn serializeAll(self: OpLog, gpa: std.mem.Allocator) ![]u8 {
        return self.serialize(gpa, &.{.{ .start = 0, .end = self.len() }});
    }

    pub fn applyWire(self: *OpLog, bytes: []const u8) !void {
        return wire.decodeInto(self, bytes);
    }

    pub fn save(self: OpLog, writer: *std.Io.Writer) !void {
        const bytes = try self.serializeAll(self.gpa);
        defer self.gpa.free(bytes);
        try writer.writeAll(bytes);
    }

    pub fn load(gpa: std.mem.Allocator, options: Options, reader: *std.Io.Reader) !OpLog {
        var oplog: OpLog = .init(gpa, options);
        errdefer oplog.deinit();

        const bytes = try reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(bytes);

        try oplog.applyWire(bytes);
        return oplog;
    }

    /// Copies everything `other` knows and this replica does not. Returns the
    /// range of new local versions.
    pub fn mergeFrom(self: *OpLog, other: *const OpLog) !void {
        var parents: std.ArrayList(Lv) = .empty;
        defer parents.deinit(self.gpa);

        for (other.cg.entries.items) |entry| {
            parents.clearRetainingCapacity();
            for (entry.parents) |p| {
                const raw = other.cg.lvToRaw(p);
                try parents.append(self.gpa, self.cg.rawToLv(raw) orelse return error.MissingParent);
            }

            const added = try self.cg.add(
                self.gpa,
                entry.agent,
                entry.seq,
                entry.seqEnd(),
                parents.items,
            ) orelse continue;

            const skipped = entry.lv_end - entry.lv - added.len();
            try self.copyOps(other, entry.lv + skipped, entry.lv_end, added.start);
        }
    }

    fn copyOps(self: *OpLog, other: *const OpLog, from: Lv, to: Lv, dest_lv: Lv) !void {
        var lv = from;
        while (lv < to) {
            const run = other.runContaining(lv);
            const offset = lv - run.lv;
            const take = @min(run.lvEnd(), to) - lv;

            try self.pushRemote(
                dest_lv + (lv - from),
                take,
                run.kind,
                run.posAt(offset),
                run.fwd,
                if (run.kind == .insert) other.contentOf(run.*, offset, take) else "",
            );

            lv += take;
        }
    }
};

const testing = std.testing;

test "typing collapses into a single run" {
    var oplog: OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "hel");
    try oplog.insert(3, "lo");

    try testing.expectEqual(@as(usize, 1), oplog.runs.items.len);
    try testing.expectEqual(@as(Lv, 5), oplog.len());
    try testing.expectEqualStrings("o", oplog.opAt(4).content);
    try testing.expectEqual(@as(u32, 4), oplog.opAt(4).pos);
}

test "backspace runs walk backwards" {
    var oplog: OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "hello");
    try oplog.backspace(4, 3);

    try testing.expectEqual(@as(usize, 2), oplog.runs.items.len);
    try testing.expectEqual(@as(u32, 4), oplog.opAt(5).pos);
    try testing.expectEqual(@as(u32, 2), oplog.opAt(7).pos);
}

test "forward deletes keep the same index" {
    var oplog: OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "hello");
    try oplog.delete(1, 3);

    try testing.expectEqual(@as(u32, 1), oplog.opAt(5).pos);
    try testing.expectEqual(@as(u32, 1), oplog.opAt(7).pos);
}

test "multi byte characters count as one op per byte" {
    var oplog: OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "héllo→");

    try testing.expectEqual(@as(Lv, 9), oplog.len());
    try testing.expectEqualStrings("\xe2", oplog.opAt(6).content);
}

test "merge copies only what the other replica has" {
    var a: OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "hi");
    try b.mergeFrom(&a);
    try b.insert(2, "!");
    try a.mergeFrom(&b);

    try testing.expectEqual(@as(Lv, 3), a.len());
    try testing.expectEqualStrings("!", a.opAt(2).content);

    // Merging twice changes nothing.
    try a.mergeFrom(&b);
    try testing.expectEqual(@as(Lv, 3), a.len());
}

test "a backspace run that passes the start of the document does not wrap" {
    var oplog: OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "abcdef");
    try oplog.backspace(3, 4);
    try oplog.delete(0, 1);

    try testing.expectEqual(@as(usize, 3), oplog.runs.items.len);
    try testing.expectEqual(@as(u32, 0), oplog.opAt(10).pos);
}
