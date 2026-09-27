const std = @import("std");
const walker = @import("walker.zig");

/// Which side of an insertion at the exact cursor position the cursor stays on.
pub const Bias = enum { before, after };

/// Moves a position through a patch. Cursors ride the transformed operations,
/// so nothing has to be kept alive between merges.
pub fn map(pos: u32, bias: Bias, patch: *walker.Patch) u32 {
    var at = pos;

    patch.reset();
    while (patch.next()) |op| switch (op) {
        .insert => |ins| {
            const count: u32 = @intCast(std.unicode.utf8CountCodepoints(ins.text) catch unreachable);
            if (ins.pos < at or (ins.pos == at and bias == .after)) at += count;
        },
        .delete => |del| {
            if (del.pos + del.len <= at) {
                at -= del.len;
            } else if (del.pos < at) {
                at = del.pos;
            }
        },
    };

    return at;
}

const testing = std.testing;

fn patchWith(gpa: std.mem.Allocator, ops: []const walker.TransformedOp) !walker.Patch {
    var patch: walker.Patch = .init(gpa);
    errdefer patch.deinit();

    for (ops) |op| switch (op) {
        .insert => |ins| try patch.pushInsertRun(
            ins.pos,
            @intCast(try std.unicode.utf8CountCodepoints(ins.text)),
            ins.text,
        ),
        .delete => |del| try patch.pushDeleteRun(del.pos, del.len),
    };

    return patch;
}

test "inserts before the cursor push it along" {
    var patch = try patchWith(testing.allocator, &.{.{ .insert = .{ .pos = 2, .text = "abc" } }});
    defer patch.deinit();

    try testing.expectEqual(@as(u32, 1), map(1, .before, &patch));
    try testing.expectEqual(@as(u32, 8), map(5, .before, &patch));
}

test "bias decides what happens at the cursor itself" {
    var patch = try patchWith(testing.allocator, &.{.{ .insert = .{ .pos = 3, .text = "xy" } }});
    defer patch.deinit();

    try testing.expectEqual(@as(u32, 3), map(3, .before, &patch));
    try testing.expectEqual(@as(u32, 5), map(3, .after, &patch));
}

test "a cursor inside a deleted range lands on its start" {
    var patch = try patchWith(testing.allocator, &.{.{ .delete = .{ .pos = 2, .len = 4 } }});
    defer patch.deinit();

    try testing.expectEqual(@as(u32, 1), map(1, .before, &patch));
    try testing.expectEqual(@as(u32, 2), map(4, .before, &patch));
    try testing.expectEqual(@as(u32, 2), map(6, .before, &patch));
    try testing.expectEqual(@as(u32, 4), map(8, .before, &patch));
}
