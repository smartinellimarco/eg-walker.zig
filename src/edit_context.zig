const std = @import("std");
const causal_graph = @import("causal_graph.zig");
const integrate_mod = @import("integrate.zig");
const item_tree = @import("item_tree.zig");
const oplog_mod = @import("oplog.zig");
const walker = @import("walker.zig");

const Lv = causal_graph.Lv;
const none = causal_graph.none;

/// Which character a run of delete events removed. Deleting a word is one
/// entry, not one per letter.
const Deleted = struct {
    lv: Lv,
    len: u32,
    target: Lv,
    // Backspacing walks left, so its events map to the range the other way.
    reversed: bool,

    fn targetOf(self: Deleted, lv: Lv) Lv {
        const offset = lv - self.lv;
        return if (self.reversed) self.target + self.len - 1 - offset else self.target + offset;
    }
};

pub const EditContext = struct {
    gpa: std.mem.Allocator,
    tree: item_tree.Tree,
    del_targets: std.ArrayList(Deleted) = .empty,
    cur_version: std.ArrayList(Lv) = .empty,
    // Length of the document in the effect version, so the state can be thrown
    // away and replaced by a placeholder of the right size.
    effect_len: u32 = 0,
    // The version this state was built from, when it was not built from the
    // start. Everything before it is a placeholder, so the state only holds
    // while that version still partitions the graph.
    floor: ?Lv = null,

    pub fn init(gpa: std.mem.Allocator) !EditContext {
        return .{ .gpa = gpa, .tree = try .init(gpa) };
    }

    pub fn deinit(self: *EditContext) void {
        self.tree.deinit();
        self.del_targets.deinit(self.gpa);
        self.cur_version.deinit(self.gpa);
    }

    /// Starts a partial replay from a critical version: the document at that
    /// point becomes one opaque run of the given length.
    pub fn seed(self: *EditContext, version: Lv, doc_len: u32) !void {
        self.floor = version;
        try self.tree.clear(version + 1);
        try self.tree.seedPlaceholder(doc_len);
        self.effect_len = doc_len;
        self.cur_version.clearRetainingCapacity();
        try self.cur_version.append(self.gpa, version);
    }

    /// At a critical version nothing before it can affect what comes after, so
    /// the whole internal state collapses back into a placeholder.
    pub fn collapse(self: *EditContext, version: Lv) !void {
        const doc_len = self.effect_len;
        self.del_targets.clearRetainingCapacity();
        try self.seed(version, doc_len);
    }

    /// Retreats a whole range at once. Events are taken from the end so items
    /// are undeleted before they are un-inserted, and runs of characters typed
    /// together move as one item instead of being shattered.
    pub fn retreatRange(self: *EditContext, oplog: *const oplog_mod.OpLog, range: causal_graph.Range) !void {
        var lv = range.end;
        while (lv > range.start) {
            lv -= try self.shift(oplog, range.start, lv - 1, -1);
        }
    }

    pub fn advanceRange(self: *EditContext, oplog: *const oplog_mod.OpLog, range: causal_graph.Range) !void {
        var lv = range.start;
        while (lv < range.end) {
            const covered = try self.shift(oplog, lv, range.end - 1, 1);
            lv += covered;
        }
    }

    /// Moves the prepare state of one item, taking as many of the events
    /// between `first` and `last` as that item covers.
    fn shift(self: *EditContext, oplog: *const oplog_mod.OpLog, first: Lv, last: Lv, delta: i32) !u32 {
        const lv = if (delta < 0) last else first;

        // Insert events stand for the character they made; delete events point
        // at one through the run that recorded them. A backspace run numbers its
        // characters the other way round, so the event being moved is the
        // anchor, not either end of the range.
        var ids: causal_graph.Range = .{ .start = first, .end = last + 1 };
        var target = lv;
        if (oplog.kindAt(lv) == .delete) {
            const run = self.deletedAt(lv);
            const from = run.targetOf(@max(first, run.lv));
            const to = run.targetOf(@min(last, run.lv + run.len - 1));
            ids = .{ .start = @min(from, to), .end = @max(from, to) + 1 };
            target = run.targetOf(lv);
        }

        var loc = self.tree.locOfId(target);
        var item = self.tree.item(loc);

        // Trim the item down to the characters this range covers.
        const item_end = item.lv + item.run_len;
        if (item_end > ids.end) {
            try self.tree.splitAt(loc, ids.end - item.lv);
            loc = self.tree.locOfId(target);
            item = self.tree.item(loc);
        }
        if (item.lv < ids.start) {
            try self.tree.splitAt(loc, ids.start - item.lv);
            loc = self.tree.locOfId(target);
            item = self.tree.item(loc);
        }

        const covered = item.run_len;
        self.tree.setCurState(loc, delta);
        return covered;
    }

    fn deletedAt(self: EditContext, lv: Lv) Deleted {
        var low: usize = 0;
        var high: usize = self.del_targets.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const run = self.del_targets.items[mid];
            if (lv < run.lv) {
                high = mid;
            } else if (lv >= run.lv + run.len) {
                low = mid + 1;
            } else {
                return run;
            }
        }
        unreachable;
    }

    pub fn applyRun(self: *EditContext, oplog: *const oplog_mod.OpLog, index: usize, lv: Lv, count: u32, patch: ?*walker.Patch) !void {
        const run = oplog.runAt(index);
        const offset = lv - run.lv;

        switch (run.kind) {
            .delete => {
                // Backspacing walks left, so the run erases one range.
                const pos = if (run.fwd) run.pos else run.pos - offset + 1 - count;
                try self.applyDelete(lv, count, pos, run.fwd, patch);
            },
            .insert => try self.applyInsert(
                oplog,
                lv,
                count,
                run.pos + offset,
                oplog.contentOf(run.*, offset, count),
                patch,
            ),
        }
    }

    fn applyDelete(self: *EditContext, lv: Lv, count: u32, pos: u32, fwd: bool, patch: ?*walker.Patch) !void {
        var cursor = try self.tree.findByPreparePos(pos);
        var remaining = count;

        const recorded = self.del_targets.items.len;

        while (remaining > 0) {
            // The cursor can land on items that are not visible in the prepare version.
            while (!self.tree.visible(cursor.loc)) {
                cursor.effect_pos += self.tree.effectWidth(cursor.loc);
                cursor.loc = self.tree.nextLoc(cursor.loc);
            }

            // Splitting can move items between leaves, so the position is taken again.
            const id = self.tree.item(cursor.loc).lv;
            const take = @min(self.tree.item(cursor.loc).run_len, remaining);
            if (self.tree.item(cursor.loc).run_len > take) {
                try self.tree.splitAt(cursor.loc, take);
                cursor.loc = self.tree.locOfId(id);
            }

            if (!self.tree.item(cursor.loc).ever_deleted) {
                if (patch) |p| try p.pushDeleteRun(cursor.effect_pos, take);
                self.effect_len -= take;
            }

            self.tree.markDeleted(cursor.loc);
            try self.tree.indexEveryId(cursor.loc);

            // Event i of a forward run deletes the i-th character of the range,
            // of a backspace run the other way around.
            try self.del_targets.append(self.gpa, .{
                .lv = if (fwd) lv + (count - remaining) else lv + remaining - take,
                .len = take,
                .target = id,
                .reversed = !fwd,
            });

            remaining -= take;
            cursor.loc = self.tree.nextLoc(cursor.loc);
        }

        // A backspace run walks the document forwards but its events backwards,
        // so its pieces come out in the wrong order for the search above.
        if (!fwd) std.mem.reverse(Deleted, self.del_targets.items[recorded..]);

    }

    fn applyInsert(self: *EditContext, oplog: *const oplog_mod.OpLog, lv: Lv, count: u32, pos: u32, text: []const u8, patch: ?*walker.Patch) !void {
        var cursor = try self.tree.findByPreparePos(pos);

        const origin_left = self.tree.idLeftOf(cursor.loc);

        var right_parent: Lv = none;
        const scan = self.tree.nextPresent(cursor.loc);
        if (!self.tree.atEnd(scan)) {
            const next = self.tree.item(scan);
            right_parent = if (next.origin_left == origin_left) next.lv else none;
        }

        const first: item_tree.Item = .{
            .lv = lv,
            .origin_left = origin_left,
            .right_parent = right_parent,
        };

        integrate_mod.integrate(&self.tree, oplog.cg, first, &cursor);
        const placed = try self.tree.insertAt(cursor.loc, first);

        // The rest of the run follows the first character with nothing able to
        // come between them, so they need no integration of their own.
        if (count > 1) {
            const rest: item_tree.Item = .{
                .lv = lv + 1,
                .run_len = count - 1,
                .origin_left = lv,
            };
            _ = try self.tree.insertAt(self.tree.nextLoc(placed), rest);
        }

        self.effect_len += count;

        if (patch) |p| try p.pushInsertRun(cursor.effect_pos, count, text);
    }
};
