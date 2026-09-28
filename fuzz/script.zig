const std = @import("std");
const egwalker = @import("egwalker");

const alphabet = "abcdefgáé→";

pub const Options = struct {
    agents: u8,
    /// How far apart the branch keeps checkpoints, and how much CRDT state it
    /// holds before dropping it: both decide how often a merge replays from a
    /// placeholder instead of from the start.
    checkpoints: u32,
    state_limit: u32,
    log: bool,
};

pub const Cmd = struct {
    kind: enum { insert, delete, merge },
    peer: u8,
    other: u8,
    pos: u16,
    count: u8,
    char: u8,
};

const Peer = struct {
    oplog: egwalker.OpLog,
    len: u32 = 0,
    // The incremental path the editor uses: a branch kept in step with patches.
    branch: egwalker.Branch,
    doc: egwalker.Text,

    fn deinit(self: *Peer) void {
        self.oplog.deinit();
        self.branch.deinit();
        self.doc.deinit();
    }

    fn catchUp(self: *Peer) !void {
        var patch = try self.branch.merge(&self.oplog);
        defer patch.deinit();
        try egwalker.applyPatch(self.doc.sink(), &patch);
    }
};

/// Replays `cmds` on the replicas and checks they all read the same text.
/// With `log`, prints every operation it actually performed.
pub fn run(gpa: std.mem.Allocator, cmds: []const Cmd, opts: Options) !void {
    const peers = try gpa.alloc(Peer, opts.agents);
    defer gpa.free(peers);

    var live: usize = 0;
    defer for (peers[0..live]) |*peer| peer.deinit();

    while (live < opts.agents) : (live += 1) {
        peers[live] = .{
            .oplog = .init(gpa, .{ .agent = live + 1 }),
            .branch = .{ .gpa = gpa, .checkpoint_interval = opts.checkpoints, .state_limit = opts.state_limit },
            .doc = try .init(gpa),
        };
    }

    for (cmds) |cmd| {
        const index = cmd.peer % opts.agents;
        const peer = &peers[index];
        switch (cmd.kind) {
            .insert => {
                const pos = if (peer.len == 0) 0 else cmd.pos % (peer.len + 1);
                var buf: [4]u8 = undefined;
                const encoded = try std.unicode.utf8Encode(charAt(cmd.char), &buf);
                try peer.oplog.insert(pos, buf[0..encoded]);
                peer.len += 1;
                if (opts.log) std.debug.print("peers[{d}].insert({d}, \"{s}\");\n", .{ index, pos, buf[0..encoded] });
            },
            .delete => {
                if (peer.len == 0) continue;
                const pos = cmd.pos % peer.len;
                const count = @min(@as(u32, cmd.count % 4) + 1, peer.len - pos);
                try peer.oplog.delete(pos, count);
                peer.len -= count;
                if (opts.log) std.debug.print("peers[{d}].delete({d}, {d});\n", .{ index, pos, count });
            },
            .merge => {
                const other_index = cmd.other % opts.agents;
                const other = &peers[other_index];
                if (other == peer) continue;
                if (cmd.count % 2 == 0) {
                    try peer.oplog.mergeFrom(&other.oplog);
                } else {
                    try syncOverWire(gpa, peer, other);
                }
                try peer.catchUp();
                peer.len = peer.doc.len();
                if (opts.log) std.debug.print("peers[{d}].mergeFrom(peers[{d}]);\n", .{ index, other_index });
            },
        }
    }

    // Everyone learns everything, then every replica must read the same text.
    for (0..opts.agents) |_| {
        for (peers, 0..) |*peer, i| {
            for (peers, 0..) |*other, j| {
                if (i == j) continue;
                try peer.oplog.mergeFrom(&other.oplog);
            }
        }
    }

    const expected = try replay(gpa, &peers[0].oplog, opts);
    defer gpa.free(expected);

    for (peers) |*peer| {
        const text = try replay(gpa, &peer.oplog, opts);
        defer gpa.free(text);
        if (!std.mem.eql(u8, expected, text)) return error.Diverged;

        try peer.catchUp();
        const incremental = try peer.doc.toUtf8(gpa);
        defer gpa.free(incremental);
        if (!std.mem.eql(u8, expected, incremental)) return error.IncrementalDiverged;
    }
}

pub fn random(gpa: std.mem.Allocator, seed: u64, count: usize) ![]Cmd {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    const cmds = try gpa.alloc(Cmd, count);
    for (cmds) |*cmd| {
        cmd.* = .{
            .kind = rand.enumValue(@FieldType(Cmd, "kind")),
            .peer = rand.int(u8),
            .other = rand.int(u8),
            .pos = rand.int(u16),
            .count = rand.int(u8),
            .char = rand.int(u8),
        };
    }
    return cmds;
}

pub fn fromSmith(gpa: std.mem.Allocator, s: *std.testing.Smith) ![]Cmd {
    var cmds: std.ArrayList(Cmd) = .empty;
    errdefer cmds.deinit(gpa);

    while (!s.eos() and cmds.items.len < 200) {
        try cmds.append(gpa, .{
            .kind = s.value(@FieldType(Cmd, "kind")),
            .peer = s.value(u8),
            .other = s.value(u8),
            .pos = s.value(u16),
            .count = s.value(u8),
            .char = s.value(u8),
        });
    }

    return cmds.toOwnedSlice(gpa);
}

/// `kind peer other pos count char`, one command per semicolon, so a whole
/// script fits in an argument and the shrinker needs no files.
pub fn print(gpa: std.mem.Allocator, cmds: []const Cmd) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (cmds) |cmd| try out.print(gpa, "{d} {d} {d} {d} {d} {d};", .{
        @intFromEnum(cmd.kind), cmd.peer, cmd.other, cmd.pos, cmd.count, cmd.char,
    });

    return out.toOwnedSlice(gpa);
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8) ![]Cmd {
    var cmds: std.ArrayList(Cmd) = .empty;
    errdefer cmds.deinit(gpa);

    var each = std.mem.tokenizeScalar(u8, text, ';');
    while (each.next()) |one| {
        var field = std.mem.tokenizeScalar(u8, one, ' ');
        try cmds.append(gpa, .{
            .kind = @enumFromInt(try std.fmt.parseInt(u8, field.next().?, 10)),
            .peer = try std.fmt.parseInt(u8, field.next().?, 10),
            .other = try std.fmt.parseInt(u8, field.next().?, 10),
            .pos = try std.fmt.parseInt(u16, field.next().?, 10),
            .count = try std.fmt.parseInt(u8, field.next().?, 10),
            .char = try std.fmt.parseInt(u8, field.next().?, 10),
        });
    }

    return cmds.toOwnedSlice(gpa);
}

fn replay(gpa: std.mem.Allocator, oplog: *const egwalker.OpLog, opts: Options) ![]u8 {
    var branch: egwalker.Branch = .{ .gpa = gpa, .checkpoint_interval = opts.checkpoints, .state_limit = opts.state_limit };
    defer branch.deinit();

    var patch = try branch.merge(oplog);
    defer patch.deinit();

    var doc: egwalker.Text = try .init(gpa);
    defer doc.deinit();
    try egwalker.applyPatch(doc.sink(), &patch);

    return doc.toUtf8(gpa);
}

fn syncOverWire(gpa: std.mem.Allocator, dest: *Peer, src: *const Peer) !void {
    var summary = try dest.oplog.versionSummary(gpa);
    defer summary.deinit();

    const ranges = try src.oplog.rangesMissing(gpa, summary);
    defer gpa.free(ranges);

    const bytes = try src.oplog.serialize(gpa, ranges);
    defer gpa.free(bytes);

    try dest.oplog.applyWire(bytes);
}

fn charAt(index: u8) u21 {
    var view = std.unicode.Utf8View.initUnchecked(alphabet);
    var chars = view.iterator();
    var count: u8 = 0;
    while (chars.nextCodepoint()) |_| count += 1;

    chars = view.iterator();
    var skip = index % count;
    while (skip > 0) : (skip -= 1) _ = chars.nextCodepoint();
    return chars.nextCodepoint().?;
}
