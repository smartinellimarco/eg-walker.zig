const std = @import("std");
const script = @import("script");

fn oneScript(_: void, s: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;

    // The shape of the session is part of what gets explored, so nothing here
    // is fixed: replica count, checkpoint spacing and how much state a branch
    // keeps all come from the same input as the operations.
    const opts: script.Options = .{
        .agents = 2 + s.value(u8) % 4,
        .checkpoints = 1 + @as(u32, s.value(u8)) % 16,
        .state_limit = 1 + @as(u32, s.value(u8)) % 64,
        .log = false,
    };

    const cmds = try script.fromSmith(gpa, s);
    defer gpa.free(cmds);

    try script.run(gpa, cmds, opts);
}

// Only runs under `zig build test --fuzz`; the plain suite has nothing
// generated in it. `zig build fuzz` is the same simulation driven by seeds.
test "replicas converge under the fuzzer" {
    try std.testing.fuzz({}, oneScript, .{});
}
