const std = @import("std");
const causal_graph = @import("causal_graph.zig");
const edit_context = @import("edit_context.zig");
const oplog_mod = @import("oplog.zig");
const text_mod = @import("text.zig");
const walker = @import("walker.zig");

const Lv = causal_graph.Lv;

const Checkpoint = struct {
    lv: Lv,
    doc_len: u32,
};

pub const Branch = struct {
    gpa: std.mem.Allocator,
    version: std.ArrayList(Lv) = .empty,
    applied: Lv = 0,
    doc_len: u32 = 0,
    checkpoints: std.ArrayList(Checkpoint) = .empty,
    // Kept alive while a divergence is open, so the next merge only pays for
    // what changed instead of replaying from the last critical version.
    live: ?edit_context.EditContext = null,
    // The state collapses at every critical version, so editing sessions hold
    // a few hundred items. A divergence that never closes has no such point,
    // and this is where that state gets dropped rather than grow for ever.
    state_limit: u32 = 1 << 16,
    // A replay starts at the newest checkpoint that still partitions the graph,
    // so a sparse sample costs a few replayed events, never correctness.
    checkpoint_interval: u32 = 512,

    pub fn init(gpa: std.mem.Allocator) Branch {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Branch) void {
        self.discard();
        self.version.deinit(self.gpa);
        self.checkpoints.deinit(self.gpa);
    }

    /// Drops the merge state. The next merge rebuilds what it needs, so this is
    /// only about memory: call it for documents nobody is editing any more.
    pub fn discard(self: *Branch) void {
        if (self.live) |*ctx| ctx.deinit();
        self.live = null;
    }

    /// Transforms everything in the oplog this branch has not seen yet. The
    /// caller owns the returned patch.
    pub fn merge(self: *Branch, oplog: *const oplog_mod.OpLog) !walker.Patch {
        var patch: walker.Patch = .init(self.gpa);
        errdefer patch.deinit();

        const target = oplog.len();
        if (self.applied == target) return patch;

        // State built on a version that no longer partitions the graph cannot
        // answer for the events before it any more.
        if (self.live) |ctx| {
            if (ctx.floor) |floor| {
                if (!oplog.cg.isCritical(floor)) self.discard();
            }
        }

        // With merge state in hand every event goes through it, otherwise it
        // would fall behind the document.
        if (self.live == null) try self.mergeSequential(oplog, &patch, target);
        if (self.applied < target) try self.mergeConcurrent(oplog, &patch, target);

        return patch;
    }

    // While every event lands on the version the branch is already at, the
    // prepare and effect versions are the same and operations need no
    // transformation at all. This is the whole point of eg-walker: no CRDT
    // state is built, and none is kept.
    fn mergeSequential(self: *Branch, oplog: *const oplog_mod.OpLog, patch: *walker.Patch, target: Lv) !void {
        var lv = self.applied;
        while (lv < target) {
            const entry = oplog.cg.entryContaining(lv);

            // Entries grow by run-length encoding, so the branch can sit in the
            // middle of one. Inside an entry every event's only parent is its
            // predecessor.
            var parent_buf: [1]Lv = undefined;
            const parents: []const Lv = if (lv == entry.lv) entry.parents else blk: {
                parent_buf[0] = lv - 1;
                break :blk parent_buf[0..1];
            };
            if (!sameVersion(parents, self.version.items)) return;

            const end = @min(entry.lv_end, target);
            var v = lv;
            var index = oplog.runIndexContaining(v);
            while (v < end) : (index += 1) {
                // Whole runs pass through at once: with no transformation to do,
                // a typed word is one operation, not one per character.
                const run = oplog.runAt(index);
                const offset = v - run.lv;
                const take = @min(run.lvEnd(), end) - v;

                switch (run.kind) {
                    .insert => {
                        try patch.pushInsertRun(run.pos + offset, take, oplog.contentOf(run.*, offset, take));
                        self.doc_len += take;
                    },
                    .delete => {
                        // Backspacing walks left, so the run erases one range.
                        const at = if (run.fwd) run.pos else run.pos - offset + 1 - take;
                        try patch.pushDeleteRun(at, take);
                        self.doc_len -= take;
                    },
                }

                v += take;
            }

            try self.setVersion(&.{end - 1});
            self.applied = end;
            try self.checkpoint(oplog, end - 1);
            lv = end;
        }
    }

    // Something concurrent showed up, so the CRDT has to be rebuilt. The state
    // lives only for this call.
    fn mergeConcurrent(self: *Branch, oplog: *const oplog_mod.OpLog, patch: *walker.Patch, target: Lv) !void {
        if (self.live == null) {
            var ctx: edit_context.EditContext = try .init(self.gpa);
            errdefer ctx.deinit();

            var from: Lv = 0;
            if (self.replayStart(oplog)) |start| {
                try ctx.seed(start.lv, start.doc_len);
                from = start.lv + 1;
            }

            try walker.walk(&ctx, oplog, null, from, self.applied);
            self.live = ctx;
        }

        const before = patch.docDelta();
        try walker.walk(&self.live.?, oplog, patch, self.applied, target);

        self.doc_len = @intCast(@as(i64, self.doc_len) + patch.docDelta() - before);
        try self.setVersion(oplog.cg.heads.items);
        self.applied = target;

        // Once the version partitions the graph again nothing concurrent is
        // left in flight, and the plain path is cheaper than keeping state.
        if (oplog.cg.heads.items.len == 1 and oplog.cg.isCritical(oplog.cg.heads.items[0])) {
            try self.checkpoint(oplog, oplog.cg.heads.items[0]);
            self.discard();
        } else if (self.live.?.tree.store.items.len > self.state_limit) {
            self.discard();
        }
    }

    // Everything before a critical version can be replaced by a placeholder, so
    // that is where a replay starts.
    fn replayStart(self: *Branch, oplog: *const oplog_mod.OpLog) ?Checkpoint {
        var i = self.checkpoints.items.len;
        while (i > 0) {
            i -= 1;
            const candidate = self.checkpoints.items[i];
            if (!oplog.cg.isCritical(candidate.lv)) continue;

            self.checkpoints.shrinkRetainingCapacity(i + 1);
            return candidate;
        }

        self.checkpoints.clearRetainingCapacity();
        return null;
    }

    fn checkpoint(self: *Branch, oplog: *const oplog_mod.OpLog, lv: Lv) !void {
        if (!oplog.cg.isCritical(lv)) return;
        if (self.checkpoints.items.len > 0) {
            const last = self.checkpoints.items[self.checkpoints.items.len - 1];
            if (lv - last.lv < self.checkpoint_interval) return;
        }
        try self.checkpoints.append(self.gpa, .{ .lv = lv, .doc_len = self.doc_len });
    }

    fn setVersion(self: *Branch, version: []const Lv) !void {
        self.version.clearRetainingCapacity();
        try self.version.appendSlice(self.gpa, version);
    }
};

fn sameVersion(a: []const Lv, b: []const Lv) bool {
    return std.mem.eql(Lv, a, b);
}

pub fn apply(doc: *text_mod.Text, patch: *walker.Patch) !void {
    patch.reset();
    while (patch.next()) |op| switch (op) {
        .insert => |ins| try doc.insertUtf8(ins.pos, ins.text),
        .delete => |del| doc.delete(del.pos, del.len),
    };
}

pub fn checkout(gpa: std.mem.Allocator, oplog: *const oplog_mod.OpLog) ![]u8 {
    var branch: Branch = .init(gpa);
    defer branch.deinit();

    var patch = try branch.merge(oplog);
    defer patch.deinit();

    var doc: text_mod.Text = try .init(gpa);
    defer doc.deinit();

    try apply(&doc, &patch);
    return doc.toUtf8(gpa);
}

const testing = std.testing;

test "single agent typing reads back" {
    var oplog: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "hello");
    try oplog.insert(5, " world");
    try oplog.delete(0, 1);
    try oplog.insert(0, "H");

    const text = try checkout(testing.allocator, &oplog);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("Hello world", text);
}

test "concurrent inserts converge on both replicas" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "Helo");
    try b.mergeFrom(&a);

    try a.insert(3, "l");
    try b.insert(4, "!");

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const text_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(text_a);
    const text_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(text_b);

    try testing.expectEqualStrings("Hello!", text_a);
    try testing.expectEqualStrings("Hello!", text_b);
}

test "concurrent delete of the same character is not applied twice" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "abc");
    try b.mergeFrom(&a);

    try a.delete(1, 1);
    try b.delete(1, 1);

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const text_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(text_a);
    const text_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(text_b);

    try testing.expectEqualStrings("ac", text_a);
    try testing.expectEqualStrings("ac", text_b);
}

test "branch merges incrementally and emits transformed ops" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "hi");

    var branch: Branch = .init(testing.allocator);
    defer branch.deinit();

    var doc: text_mod.Text = try .init(testing.allocator);
    defer doc.deinit();

    var first = try branch.merge(&a);
    defer first.deinit();
    try apply(&doc, &first);
    try testing.expectEqual(@as(u32, 2), doc.len());

    try b.mergeFrom(&a);
    try b.insert(0, "oh ");
    try a.mergeFrom(&b);

    var second = try branch.merge(&a);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.len());
    try apply(&doc, &second);

    const out = try doc.toUtf8(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("oh hi", out);
}

test "backspacing one character at a time reads back" {
    var oplog: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "hello world");

    // Five separate events, the way a user actually holds backspace.
    var pos: u32 = 10;
    while (pos >= 6) : (pos -= 1) try oplog.delete(pos, 1);

    try testing.expectEqual(@as(usize, 2), oplog.runs.items.len);

    const text = try checkout(testing.allocator, &oplog);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("hello ", text);
}

test "a forward delete run after a single delete" {
    var oplog: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "abcdef");
    try oplog.delete(1, 1);
    try oplog.delete(1, 2);

    const text = try checkout(testing.allocator, &oplog);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("aef", text);
}

test "a divergence that never closes stops growing state" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();

    try a.insert(0, "hello");
    const forked = a.version()[0];

    var branch: Branch = .{ .gpa = testing.allocator, .state_limit = 4 };
    defer branch.deinit();

    var first = try branch.merge(&a);
    first.deinit();

    // Two branches that never meet, so the version is never critical again.
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        _ = try a.insertAt(2, &.{forked}, 0, "x");
        _ = try a.insertAt(3, &.{forked}, 0, "y");

        var patch = try branch.merge(&a);
        patch.deinit();
    }

    try testing.expect(branch.live == null);

    const text = try checkout(testing.allocator, &a);
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 85), text.len);
}

test "a branch that already merged an entry checks the parents of the next one" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "he");
    try b.mergeFrom(&a);
    try b.insert(2, "X");

    // Agent 1 keeps typing, so its events stay one run-length encoded entry
    // while agent 2 forked off the middle of it.
    try a.insert(2, "llo");

    var branch: Branch = .init(testing.allocator);
    defer branch.deinit();

    var doc: text_mod.Text = try .init(testing.allocator);
    defer doc.deinit();

    var first = try branch.merge(&a);
    defer first.deinit();
    try apply(&doc, &first);

    try a.mergeFrom(&b);

    var second = try branch.merge(&a);
    defer second.deinit();
    try apply(&doc, &second);

    const out = try doc.toUtf8(testing.allocator);
    defer testing.allocator.free(out);

    const whole = try checkout(testing.allocator, &a);
    defer testing.allocator.free(whole);

    try testing.expectEqualStrings(whole, out);
    try testing.expectEqualStrings("helloX", out);
}

test "concurrent backspace runs converge" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();
    var c: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 3 });
    defer c.deinit();

    try a.insert(0, "hello world hello world");
    try c.mergeFrom(&a);
    try c.insert(11, "ABCDE");
    try a.mergeFrom(&c);
    try b.mergeFrom(&a);

    // One holds backspace while the other types inside what it is erasing.
    try a.backspace(22, 12);
    try b.insert(20, "X");
    try b.insert(16, "Y");
    try b.insert(12, "Z");
    try b.backspace(4, 3);

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const from_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(from_a);
    const from_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(from_b);

    try testing.expectEqualStrings(from_a, from_b);
    try testing.expectEqualStrings("he worldZYXworld", from_a);
}

test "concurrent inserts inside one typed run converge" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "hello");
    try b.mergeFrom(&a);

    // Both land in the middle of the same run, which has to split.
    try a.insert(2, "Y");
    try b.insert(2, "X");

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const from_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(from_a);
    const from_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(from_b);

    try testing.expectEqualStrings(from_a, from_b);
    try testing.expectEqualStrings("heYXllo", from_a);
}

test "a backspace run retreats by the id of the event being moved" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();
    var c: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 3 });
    defer c.deinit();

    try c.insert(0, "b");
    try c.insert(1, "é");
    try b.mergeFrom(&c);
    try c.delete(1, 1);
    try b.delete(1, 1);
    try a.mergeFrom(&b);
    try b.delete(0, 1);
    try a.insert(0, "g");
    try b.mergeFrom(&a);
    try b.insert(0, "g");

    try a.mergeFrom(&b);
    try a.mergeFrom(&c);
    try b.mergeFrom(&a);
    try c.mergeFrom(&a);

    // Short enough that the merge replays from a placeholder instead of from
    // the start, which is where the retreat runs over a whole backspace run.
    const from_a = try checkoutInSteps(testing.allocator, &a);
    defer testing.allocator.free(from_a);
    const from_b = try checkoutInSteps(testing.allocator, &b);
    defer testing.allocator.free(from_b);
    const from_c = try checkoutInSteps(testing.allocator, &c);
    defer testing.allocator.free(from_c);

    try testing.expectEqualStrings(from_a, from_b);
    try testing.expectEqualStrings(from_a, from_c);
    try testing.expectEqualStrings("gg", from_a);
}

fn checkoutInSteps(gpa: std.mem.Allocator, oplog: *const oplog_mod.OpLog) ![]u8 {
    var branch: Branch = .{ .gpa = gpa, .checkpoint_interval = 2 };
    defer branch.deinit();

    var patch = try branch.merge(oplog);
    defer patch.deinit();

    var doc: text_mod.Text = try .init(gpa);
    defer doc.deinit();
    try apply(&doc, &patch);

    return doc.toUtf8(gpa);
}
