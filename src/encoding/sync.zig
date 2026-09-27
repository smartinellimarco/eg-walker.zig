const std = @import("std");
const agent = @import("../agent.zig");
const causal_graph = @import("../causal_graph.zig");
const varint = @import("varint.zig");

const Lv = causal_graph.Lv;

pub const SeqRange = struct {
    start: agent.Seq,
    end: agent.Seq,
};

/// What a replica knows, expressed per agent so it can be compared without
/// sharing local version numbers.
pub const VersionSummary = struct {
    gpa: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(agent.Id, std.ArrayList(SeqRange)) = .empty,

    pub fn init(gpa: std.mem.Allocator) VersionSummary {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *VersionSummary) void {
        var it = self.entries.valueIterator();
        while (it.next()) |ranges| ranges.deinit(self.gpa);
        self.entries.deinit(self.gpa);
    }

    pub fn add(self: *VersionSummary, id: agent.Id, range: SeqRange) !void {
        const gop = try self.entries.getOrPut(self.gpa, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;

        const ranges = gop.value_ptr;
        if (ranges.items.len > 0) {
            const last = &ranges.items[ranges.items.len - 1];
            if (last.end == range.start) {
                last.end = range.end;
                return;
            }
        }
        try ranges.append(self.gpa, range);
    }

    pub fn contains(self: VersionSummary, id: agent.Id, seq: agent.Seq) bool {
        const ranges = self.entries.get(id) orelse return false;
        for (ranges.items) |range| {
            if (seq >= range.start and seq < range.end) return true;
        }
        return false;
    }

    pub fn encode(self: VersionSummary, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try varint.write(gpa, &out, self.entries.count());

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            try varint.write(gpa, &out, kv.key_ptr.*);
            try varint.write(gpa, &out, kv.value_ptr.items.len);
            for (kv.value_ptr.items) |range| {
                try varint.write(gpa, &out, range.start);
                try varint.write(gpa, &out, range.end - range.start);
            }
        }

        return out.toOwnedSlice(gpa);
    }

    pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !VersionSummary {
        var summary: VersionSummary = .init(gpa);
        errdefer summary.deinit();

        var reader: varint.Reader = .{ .bytes = bytes };
        var agents = try reader.read();
        while (agents > 0) : (agents -= 1) {
            const id = try reader.read();
            var ranges = try reader.read();
            while (ranges > 0) : (ranges -= 1) {
                const start = try reader.readInt(agent.Seq);
                const len = try reader.readInt(agent.Seq);
                try summary.add(id, .{ .start = start, .end = start + len });
            }
        }

        return summary;
    }
};

pub fn summarize(gpa: std.mem.Allocator, cg: causal_graph.CausalGraph) !VersionSummary {
    var summary: VersionSummary = .init(gpa);
    errdefer summary.deinit();

    for (cg.entries.items) |entry| {
        try summary.add(entry.agent, .{ .start = entry.seq, .end = entry.seqEnd() });
    }

    return summary;
}

/// The local version ranges that `theirs` is missing, in causal order.
pub fn rangesMissing(gpa: std.mem.Allocator, cg: causal_graph.CausalGraph, theirs: VersionSummary) ![]causal_graph.Range {
    var ranges: std.ArrayList(causal_graph.Range) = .empty;
    errdefer ranges.deinit(gpa);

    for (cg.entries.items) |entry| {
        var lv = entry.lv;
        while (lv < entry.lv_end) : (lv += 1) {
            const seq = entry.seq + @as(agent.Seq, @intCast(lv - entry.lv));
            if (theirs.contains(entry.agent, seq)) continue;

            if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1].end == lv) {
                ranges.items[ranges.items.len - 1].end = lv + 1;
            } else {
                try ranges.append(gpa, .{ .start = lv, .end = lv + 1 });
            }
        }
    }

    return ranges.toOwnedSlice(gpa);
}

const testing = std.testing;

test "summary round trips through bytes" {
    var summary: VersionSummary = .init(testing.allocator);
    defer summary.deinit();

    try summary.add(7, .{ .start = 0, .end = 4 });
    try summary.add(7, .{ .start = 4, .end = 9 });
    try summary.add(9, .{ .start = 0, .end = 1 });

    const bytes = try summary.encode(testing.allocator);
    defer testing.allocator.free(bytes);

    var decoded = try VersionSummary.decode(testing.allocator, bytes);
    defer decoded.deinit();

    try testing.expect(decoded.contains(7, 8));
    try testing.expect(!decoded.contains(7, 9));
    try testing.expect(decoded.contains(9, 0));
    try testing.expect(!decoded.contains(3, 0));
}
