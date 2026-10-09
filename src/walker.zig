const std = @import("std");
const causal_graph = @import("causal_graph.zig");
const edit_context = @import("edit_context.zig");
const oplog_mod = @import("oplog.zig");

const Lv = causal_graph.Lv;

pub const TransformedOp = union(enum) {
    insert: struct { pos: u32, text: []const u8 },
    delete: struct { pos: u32, len: u32 },
};

const RawOp = union(enum) {
    // The text is borrowed from the oplog, which always outlives the patch.
    insert: struct { pos: u32, count: u32, text: []const u8 },
    delete: struct { pos: u32, len: u32 },
};

pub const Patch = struct {
    gpa: std.mem.Allocator,
    raw: std.ArrayList(RawOp) = .empty,
    cursor: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Patch {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Patch) void {
        self.raw.deinit(self.gpa);
    }

    pub fn len(self: Patch) usize {
        return self.raw.items.len;
    }

    pub fn next(self: *Patch) ?TransformedOp {
        if (self.cursor == self.raw.items.len) return null;
        defer self.cursor += 1;
        return switch (self.raw.items[self.cursor]) {
            .insert => |op| .{ .insert = .{ .pos = op.pos, .text = op.text } },
            .delete => |op| .{ .delete = .{ .pos = op.pos, .len = op.len } },
        };
    }

    pub fn reset(self: *Patch) void {
        self.cursor = 0;
    }

    /// How much the document grows or shrinks, in bytes.
    pub fn docDelta(self: Patch) i64 {
        var delta: i64 = 0;
        for (self.raw.items) |op| switch (op) {
            .insert => |ins| delta += ins.count,
            .delete => |del| delta -= del.len,
        };
        return delta;
    }

    pub fn pushInsertRun(self: *Patch, pos: u32, count: u32, text: []const u8) !void {
        if (self.raw.items.len > 0) {
            switch (self.raw.items[self.raw.items.len - 1]) {
                .insert => |*last| {
                    // Runs merge only while they stay adjacent in the oplog too,
                    // since the text is borrowed from there.
                    if (last.pos + last.count == pos and last.text.ptr + last.text.len == text.ptr) {
                        last.count += count;
                        last.text.len += text.len;
                        return;
                    }
                },
                .delete => {},
            }
        }

        try self.raw.append(self.gpa, .{ .insert = .{ .pos = pos, .count = count, .text = text } });
    }

    pub fn pushDeleteRun(self: *Patch, pos: u32, count: u32) !void {
        if (self.raw.items.len > 0) {
            switch (self.raw.items[self.raw.items.len - 1]) {
                // Deleting consecutive bytes keeps hitting the same index.
                .delete => |*last| {
                    if (last.pos == pos) {
                        last.len += count;
                        return;
                    }
                },
                .insert => {},
            }
        }

        try self.raw.append(self.gpa, .{ .delete = .{ .pos = pos, .len = count } });
    }
};

pub fn walk(
    ctx: *edit_context.EditContext,
    oplog: *const oplog_mod.OpLog,
    patch: ?*Patch,
    from: Lv,
    to: Lv,
) !void {
    const gpa = ctx.gpa;

    var ws: causal_graph.Workspace = .init(gpa);
    defer ws.deinit();

    var lv = from;

    while (lv < to) {
        const entry = oplog.cg.entryContaining(lv);
        const end = @min(entry.lv_end, to);

        var parent_buf: [1]Lv = undefined;
        const parents: []const Lv = if (lv == entry.lv) entry.parents else blk: {
            parent_buf[0] = lv - 1;
            break :blk parent_buf[0..1];
        };

        // Events that land straight on the version already in hand need no
        // diff at all, which is most of them while a branch runs on.
        if (!std.mem.eql(Lv, parents, ctx.cur_version.items)) {
            try oplog.cg.diff(&ws, ctx.cur_version.items, parents);

            // Undelete before un-inserting, so walk the retreats backwards.
            var i = ws.a_only.items.len;
            while (i > 0) {
                i -= 1;
                try ctx.retreatRange(oplog, ws.a_only.items[i]);
            }

            for (ws.b_only.items) |range| try ctx.advanceRange(oplog, range);
        }

        var v = lv;
        var index = oplog.runIndexContaining(v);
        while (v < end) : (index += 1) {
            const run = oplog.runAt(index);
            const take = @min(run.lvEnd(), end) - v;
            try ctx.applyRun(oplog, index, v, take, patch);
            v += take;
        }

        if (oplog.cg.isCritical(end - 1)) {
            try ctx.collapse(end - 1);
        } else {
            ctx.cur_version.clearRetainingCapacity();
            try ctx.cur_version.append(gpa, end - 1);
        }

        lv = end;
    }
}

const testing = std.testing;

test "patch merges consecutive inserts and deletes" {
    var patch: Patch = .init(testing.allocator);
    defer patch.deinit();

    // Adjacent in the oplog is what lets two runs merge.
    const content = "hi";
    try patch.pushInsertRun(0, 1, content[0..1]);
    try patch.pushInsertRun(1, 1, content[1..2]);
    try patch.pushDeleteRun(4, 1);
    try patch.pushDeleteRun(4, 1);

    try testing.expectEqual(@as(usize, 2), patch.len());
    try testing.expectEqualStrings("hi", patch.next().?.insert.text);
    try testing.expectEqual(@as(u32, 2), patch.next().?.delete.len);
    try testing.expect(patch.next() == null);
}
