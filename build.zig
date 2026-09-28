const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rope = b.dependency("rope", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("egwalker", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "rope", .module = rope.module("rope") }},
    });

    const script_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/script.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "egwalker", .module = mod },
            .{ .name = "rope", .module = rope.module("rope") },
        },
    });

    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "script", .module = script_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const fuzz = b.addExecutable(.{
        .name = "egwalker-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "script", .module = script_mod }},
        }),
    });

    const fuzz_step = b.step("fuzz", "Search for a script of concurrent edits that diverges");
    const run_fuzz = b.addRunArtifact(fuzz);
    if (b.args) |args| run_fuzz.addArgs(args);
    fuzz_step.dependOn(&run_fuzz.step);
}
