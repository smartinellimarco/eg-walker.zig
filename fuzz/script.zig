const std = @import("std");
const egwalker = @import("egwalker");
const rope = @import("rope");

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
    // What the peer reads right now, to land edits between characters.
    text: std.ArrayList(u8) = .empty,
    // The incremental path the editor uses: a branch kept in step with patches.
    branch: egwalker.Branch,
    doc: rope.Text,

    fn deinit(self: *Peer, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.oplog.deinit();
        self.branch.deinit();
        self.doc.deinit();
    }

    fn catchUp(self: *Peer) !void {
        var patch = try self.branch.merge(&self.oplog);
        defer patch.deinit();
        try egwalker.applyPatch(sinkOf(&self.doc), &patch);
    }
};

/// Replays `cmds` on the replicas and checks they all read the same text.
/// With `log`, prints every operation it actually performed.
pub fn run(gpa: std.mem.Allocator, cmds: []const Cmd, opts: Options) !void {
    const peers = try gpa.alloc(Peer, opts.agents);
    defer gpa.free(peers);

    var live: usize = 0;
    defer for (peers[0..live]) |*peer| peer.deinit(gpa);

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
                const len: u32 = @intCast(peer.text.items.len);
                const pos = boundary(peer.text.items, if (len == 0) 0 else cmd.pos % (len + 1));
                var buf: [4]u8 = undefined;
                const char = buf[0..try std.unicode.utf8Encode(charAt(cmd.char), &buf)];
                try peer.oplog.insert(pos, char);
                try peer.text.insertSlice(gpa, pos, char);
                if (opts.log) std.debug.print("peers[{d}].insert({d}, \"{s}\");\n", .{ index, pos, char });
            },
            .delete => {
                const len: u32 = @intCast(peer.text.items.len);
                if (len == 0) continue;
                const pos = boundary(peer.text.items, cmd.pos % len);
                // One to four whole characters, however many bytes that is.
                var end = pos;
                var chars = cmd.count % 4 + 1;
                while (chars > 0 and end < len) : (chars -= 1) end += try std.unicode.utf8ByteSequenceLength(peer.text.items[end]);
                const count = end - pos;
                try peer.oplog.delete(pos, count);
                peer.text.replaceRangeAssumeCapacity(pos, count, &.{});
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
                peer.text.deinit(gpa);
                peer.text = .fromOwnedSlice(try peer.doc.toBytes(gpa));
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
    if (!std.unicode.utf8ValidateSlice(expected)) return error.SplitCharacter;

    for (peers) |*peer| {
        const text = try replay(gpa, &peer.oplog, opts);
        defer gpa.free(text);
        if (!std.mem.eql(u8, expected, text)) return error.Diverged;

        try peer.catchUp();
        const incremental = try peer.doc.toBytes(gpa);
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

fn sinkOf(text: *rope.Text) egwalker.Sink {
    const glue = struct {
        fn insert(ptr: *anyopaque, pos: u32, text_: []const u8) egwalker.sink.Error!void {
            return @as(*rope.Text, @ptrCast(@alignCast(ptr))).insert(pos, text_);
        }
        fn delete(ptr: *anyopaque, pos: u32, count: u32) void {
            @as(*rope.Text, @ptrCast(@alignCast(ptr))).delete(pos, count);
        }
    };

    return .{ .ptr = text, .vtable = &.{ .insert = glue.insert, .delete = glue.delete } };
}

fn replay(gpa: std.mem.Allocator, oplog: *const egwalker.OpLog, opts: Options) ![]u8 {
    var branch: egwalker.Branch = .{ .gpa = gpa, .checkpoint_interval = opts.checkpoints, .state_limit = opts.state_limit };
    defer branch.deinit();

    var patch = try branch.merge(oplog);
    defer patch.deinit();

    var doc: rope.Text = try .init(gpa);
    defer doc.deinit();
    try egwalker.applyPatch(sinkOf(&doc), &patch);

    return doc.toBytes(gpa);
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

fn boundary(text: []const u8, pos: u32) u32 {
    var at = pos;
    while (at < text.len and text[at] & 0xc0 == 0x80) at -= 1;
    return at;
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
