const std = @import("std");
const script = @import("script");

const usage =
    \\usage:
    \\  fuzz --agents N --ops N --checkpoints N --state-limit N --from SEED --to SEED
    \\  fuzz --agents N --ops N --checkpoints N --state-limit N --seed SEED [--log]
    \\  fuzz --agents N --ops N --checkpoints N --state-limit N --shrink SEED
    \\  fuzz --agents N --checkpoints N --state-limit N --run SCRIPT [--log]
;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    const self = args.next() orelse std.process.fatal(usage, .{});

    var agents: ?u8 = null;
    var ops: ?usize = null;
    var checkpoints: ?u32 = null;
    var state_limit: ?u32 = null;
    var from: ?u64 = null;
    var to: ?u64 = null;
    var seed: ?u64 = null;
    var shrink: ?u64 = null;
    var given: ?[]const u8 = null;
    var log = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--log")) {
            log = true;
            continue;
        }

        const value = args.next() orelse std.process.fatal(usage, .{});
        if (std.mem.eql(u8, arg, "--agents")) {
            agents = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, arg, "--ops")) {
            ops = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--checkpoints")) {
            checkpoints = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--state-limit")) {
            state_limit = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--from")) {
            from = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--to")) {
            to = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--shrink")) {
            shrink = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--run")) {
            given = value;
        } else std.process.fatal(usage, .{});
    }

    const opts: script.Options = .{
        .agents = agents orelse std.process.fatal(usage, .{}),
        .checkpoints = checkpoints orelse std.process.fatal(usage, .{}),
        .state_limit = state_limit orelse std.process.fatal(usage, .{}),
        .log = log,
    };

    if (given) |text| {
        const cmds = try script.parse(gpa, text);
        defer gpa.free(cmds);
        return script.run(gpa, cmds, opts);
    }

    const op_count = ops orelse std.process.fatal(usage, .{});
    const shared: Shared = .{ .self = self, .io = init.io, .opts = opts, .ops = op_count };

    if (shrink) |which| return shrinkSeed(gpa, shared, which);

    if (seed) |which| {
        const cmds = try script.random(gpa, which, op_count);
        defer gpa.free(cmds);
        return script.run(gpa, cmds, opts);
    }

    const first = from orelse std.process.fatal(usage, .{});
    const last = to orelse std.process.fatal(usage, .{});

    var which = first;
    while (which < last) : (which += 1) {
        const cmds = try script.random(gpa, which, op_count);
        defer gpa.free(cmds);

        if (!try survives(gpa, shared, cmds)) {
            std.debug.print("seed {d} diverged\n", .{which});
            std.debug.print("shrink it with the same arguments and --shrink {d}\n", .{which});
            std.process.exit(1);
        }
    }

    std.debug.print("seeds {d}..{d} of {d} ops over {d} agents, all converged\n", .{ first, last, op_count, opts.agents });
}

const Shared = struct {
    self: []const u8,
    io: std.Io,
    opts: script.Options,
    ops: usize,
};

fn shrinkSeed(gpa: std.mem.Allocator, shared: Shared, seed: u64) !void {
    var cmds = try script.random(gpa, seed, shared.ops);
    defer gpa.free(cmds);

    if (try survives(gpa, shared, cmds)) std.process.fatal("seed {d} converges, nothing to shrink", .{seed});

    var chunk = cmds.len / 2;
    while (chunk > 0) : (chunk /= 2) {
        var at: usize = 0;
        while (at + chunk <= cmds.len) {
            const candidate = try gpa.alloc(script.Cmd, cmds.len - chunk);
            @memcpy(candidate[0..at], cmds[0..at]);
            @memcpy(candidate[at..], cmds[at + chunk ..]);

            if (candidate.len > 0 and !try survives(gpa, shared, candidate)) {
                gpa.free(cmds);
                cmds = candidate;
            } else {
                gpa.free(candidate);
                at += chunk;
            }
        }
    }

    const text = try script.print(gpa, cmds);
    defer gpa.free(text);
    std.debug.print("{d} ops left, replay them with --run '{s}'\n\n", .{ cmds.len, text });

    // The replay runs in a child too: what is left may be a script that
    // asserts or hangs, and the transcript it printed first is the point.
    const result = try std.process.run(gpa, shared.io, .{
        .argv = &.{ shared.self, "--agents", try count(gpa, shared.opts.agents), "--checkpoints", try count(gpa, shared.opts.checkpoints), "--state-limit", try count(gpa, shared.opts.state_limit), "--log", "--run", text },
        .timeout = timeout,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    std.debug.print("{s}", .{result.stderr});
}

// A corrupt state can also spin forever, so a script that does not finish
// counts as a failure like any other.
const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

fn survives(gpa: std.mem.Allocator, shared: Shared, cmds: []const script.Cmd) !bool {
    const text = try script.print(gpa, cmds);
    defer gpa.free(text);

    const result = std.process.run(gpa, shared.io, .{
        .argv = &.{ shared.self, "--agents", try count(gpa, shared.opts.agents), "--checkpoints", try count(gpa, shared.opts.checkpoints), "--state-limit", try count(gpa, shared.opts.state_limit), "--run", text },
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.Timeout => return false,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
}

fn count(gpa: std.mem.Allocator, value: u32) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{d}", .{value});
}
