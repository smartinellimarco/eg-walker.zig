const std = @import("std");

pub const Id = u64;
pub const Seq = u32;

pub const RawVersion = struct {
    agent: Id,
    seq: Seq,

    pub fn order(a: RawVersion, b: RawVersion) std.math.Order {
        if (a.agent != b.agent) return std.math.order(a.agent, b.agent);
        return std.math.order(a.seq, b.seq);
    }
};

// Two replicas that pick the same id diverge silently, so the entropy comes
// from outside the process and a failure to get it is an error, not a fallback.
pub fn randomId(io: std.Io) !Id {
    var bytes: [@sizeOf(Id)]u8 = undefined;
    try io.randomSecure(&bytes);
    return std.mem.readInt(Id, &bytes, .little);
}

test "ids do not repeat" {
    const a = try randomId(std.testing.io);
    const b = try randomId(std.testing.io);
    try std.testing.expect(a != b);
}

test "order is total across agents and seqs" {
    const a: RawVersion = .{ .agent = 1, .seq = 7 };
    const b: RawVersion = .{ .agent = 2, .seq = 0 };
    const c: RawVersion = .{ .agent = 1, .seq = 8 };

    try std.testing.expectEqual(std.math.Order.lt, RawVersion.order(a, b));
    try std.testing.expectEqual(std.math.Order.gt, RawVersion.order(b, a));
    try std.testing.expectEqual(std.math.Order.lt, RawVersion.order(a, c));
    try std.testing.expectEqual(std.math.Order.eq, RawVersion.order(a, a));
}
