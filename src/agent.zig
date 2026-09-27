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

// Two replicas that pick the same id diverge silently, so ids come from the CSPRNG.
pub fn randomId() Id {
    return std.crypto.random.int(Id);
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
