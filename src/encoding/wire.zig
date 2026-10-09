const std = @import("std");
const agent = @import("../agent.zig");
const causal_graph = @import("../causal_graph.zig");
const oplog_mod = @import("../oplog.zig");
const varint = @import("varint.zig");

const Lv = causal_graph.Lv;

pub const magic = "egw";
pub const format_version: u8 = 1;

const Section = enum(u8) {
    events = 1,
    ops = 2,
    content = 3,
};

const SectionData = struct {
    count: u64,
    payload: []const u8,
};

/// Where a stretch of the message's events landed, so parents can be written as
/// a distance back through the message instead of a full id each time.
const Emitted = struct {
    lv: Lv,
    count: u32,
    offset: u64,
};

fn messageIndexOf(emitted: []const Emitted, lv: Lv) ?u64 {
    var low: usize = 0;
    var high: usize = emitted.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const span = emitted[mid];
        if (lv < span.lv) {
            high = mid;
        } else if (lv >= span.lv + span.count) {
            low = mid + 1;
        } else {
            return span.offset + (lv - span.lv);
        }
    }
    return null;
}

const DecodedRun = struct {
    kind: oplog_mod.OpKind,
    fwd: bool,
    len: u32,
    pos: u32,
    content_start: u32,

    fn posAt(self: DecodedRun, offset: u32) u32 {
        return switch (self.kind) {
            .insert => self.pos + offset,
            .delete => if (self.fwd) self.pos else self.pos - offset,
        };
    }

    fn textAt(self: DecodedRun, content: []const u8, offset: u32, count: u32) []const u8 {
        if (self.kind == .delete) return "";

        return content[self.content_start + offset ..][0..count];
    }
};

/// Encodes the given local version ranges so another replica can merge them.
/// Parents are written as (agent, seq) because local versions mean nothing to
/// a peer.
pub fn encode(gpa: std.mem.Allocator, oplog: *const oplog_mod.OpLog, ranges: []const causal_graph.Range) ![]u8 {
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(gpa);
    var ops: std.ArrayList(u8) = .empty;
    defer ops.deinit(gpa);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);

    var event_count: u64 = 0;
    var run_count: u64 = 0;
    var prev_pos: i64 = 0;

    var emitted: std.ArrayList(Emitted) = .empty;
    defer emitted.deinit(gpa);

    var seqs: std.AutoHashMapUnmanaged(agent.Id, agent.Seq) = .empty;
    defer seqs.deinit(gpa);

    var event_offset: u64 = 0;
    for (ranges) |range| {
        var lv = range.start;
        while (lv < range.end) {
            const entry = oplog.cg.entryContaining(lv);
            const end = @min(entry.lv_end, range.end);
            const offset = lv - entry.lv;

            const seq = entry.seq + offset;
            const count = end - lv;

            // An agent's events usually carry on from where it left off.
            const expected = seqs.get(entry.agent) orelse 0;
            try varint.write(gpa, &events, entry.agent);
            try varint.write(gpa, &events, varint.zigzag(@as(i64, seq) - expected));
            try varint.write(gpa, &events, count);
            try seqs.put(gpa, entry.agent, seq + count);

            // Inside an entry every event's only parent is its predecessor.
            const parents: []const Lv = if (lv == entry.lv) entry.parents else &.{lv - 1};
            const here = event_offset;

            // Zero stands for "the event written just before this one", which is
            // what a linear stretch of history looks like.
            if (parents.len == 1 and here > 0 and messageIndexOf(emitted.items, parents[0]) == here - 1) {
                try varint.write(gpa, &events, 0);
            } else {
                try varint.write(gpa, &events, parents.len + 1);
                for (parents) |parent| {
                    // Parents inside the message are a step back through it;
                    // anything older needs its id spelled out.
                    if (messageIndexOf(emitted.items, parent)) |at| {
                        try varint.write(gpa, &events, here - at);
                    } else {
                        try varint.write(gpa, &events, 0);
                        try writeRaw(gpa, &events, oplog.cg.lvToRaw(parent));
                    }
                }
            }

            try emitted.append(gpa, .{ .lv = lv, .count = count, .offset = event_offset });
            event_offset += count;
            event_count += 1;
            lv = end;
        }

        lv = range.start;
        while (lv < range.end) {
            const run = oplog.runContaining(lv);
            const end = @min(run.lvEnd(), range.end);
            const offset = lv - run.lv;
            const pos = run.posAt(offset);

            const text = if (run.kind == .insert) oplog.contentOf(run.*, offset, end - lv) else "";

            try varint.write(gpa, &ops, end - lv);
            try ops.append(gpa, @as(u8, @intFromEnum(run.kind)) | (@as(u8, @intFromBool(run.fwd)) << 1));
            try varint.write(gpa, &ops, varint.zigzag(@as(i64, pos) - prev_pos));
            prev_pos = pos;
            run_count += 1;

            try content.appendSlice(gpa, text);

            lv = end;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, magic);
    try out.append(gpa, format_version);

    try writeSection(gpa, &out, .events, event_count, events.items);
    try writeSection(gpa, &out, .ops, run_count, ops.items);
    try writeSection(gpa, &out, .content, content.items.len, content.items);

    return out.toOwnedSlice(gpa);
}

fn writeRaw(gpa: std.mem.Allocator, out: *std.ArrayList(u8), raw: agent.RawVersion) !void {
    try varint.write(gpa, out, raw.agent);
    try varint.write(gpa, out, raw.seq);
}

fn writeSection(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    section: Section,
    count: u64,
    payload: []const u8,
) !void {
    const packed_payload = try deflate(gpa, payload);
    defer gpa.free(packed_payload);

    try out.append(gpa, @intFromEnum(section));
    try varint.write(gpa, out, count);
    try varint.write(gpa, out, payload.len);
    try varint.write(gpa, out, packed_payload.len);
    try out.appendSlice(gpa, packed_payload);
}

/// The caller owns the returned payload.
fn readSection(gpa: std.mem.Allocator, reader: *varint.Reader, expected: Section) !SectionData {
    const tag = (try reader.take(1))[0];
    if (tag != @intFromEnum(expected)) return error.UnexpectedSection;

    const count = try reader.read();
    const size = try reader.readInt(usize);
    const stored = try reader.readInt(usize);

    return .{ .count = count, .payload = try inflate(gpa, try reader.take(stored), size) };
}

const compress_columns = true;

fn deflate(gpa: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (!compress_columns) return gpa.dupe(u8, payload);

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, payload.len / 2));
    defer out.deinit();

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var compress = try std.compress.flate.Compress.init(&out.writer, window, .raw, .level_4);
    try compress.writer.writeAll(payload);
    try compress.finish();

    return gpa.dupe(u8, out.written());
}

fn inflate(gpa: std.mem.Allocator, payload: []const u8, size: usize) ![]u8 {
    if (!compress_columns) {
        std.debug.assert(payload.len == size);
        return gpa.dupe(u8, payload);
    }

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var reader: std.Io.Reader = .fixed(payload);
    var decompress: std.compress.flate.Decompress = .init(&reader, .raw, window);

    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);

    try decompress.reader.readSliceAll(out);
    return out;
}

/// Merges a message into the oplog, skipping events it already knows.
pub fn decodeInto(oplog: *oplog_mod.OpLog, bytes: []const u8) !void {
    const gpa = oplog.gpa;

    var reader: varint.Reader = .{ .bytes = bytes };
    if (!std.mem.eql(u8, magic, try reader.take(magic.len))) return error.BadMagic;
    if ((try reader.take(1))[0] != format_version) return error.UnsupportedVersion;

    const events = try readSection(gpa, &reader, .events);
    defer gpa.free(events.payload);
    const ops = try readSection(gpa, &reader, .ops);
    defer gpa.free(ops.payload);
    const content = try readSection(gpa, &reader, .content);
    defer gpa.free(content.payload);

    var runs = try decodeRuns(gpa, ops);
    defer runs.deinit(gpa);

    // The message says exactly how much is coming.
    try oplog.content.ensureUnusedCapacity(gpa, content.payload.len);
    try oplog.runs.ensureUnusedCapacity(gpa, runs.items.len);

    var event_reader: varint.Reader = .{ .bytes = events.payload };
    var parents: std.ArrayList(Lv) = .empty;
    defer parents.deinit(gpa);

    var run_idx: usize = 0;
    var run_offset: u32 = 0;
    var remaining = events.count;

    // The message's events in order, so a parent written as a distance back
    // through the message can be turned into a local version.
    var received: std.ArrayList(Received) = .empty;
    defer received.deinit(gpa);

    var seqs: std.AutoHashMapUnmanaged(agent.Id, agent.Seq) = .empty;
    defer seqs.deinit(gpa);

    var event_offset: u64 = 0;
    while (remaining > 0) : (remaining -= 1) {
        const id = try event_reader.read();
        const expected = seqs.get(id) orelse 0;
        const seq: agent.Seq = @intCast(@as(i64, expected) + varint.unzigzag(try event_reader.read()));
        const count = try event_reader.readInt(u32);
        try seqs.put(gpa, id, seq + count);

        parents.clearRetainingCapacity();
        var parent_count = try event_reader.read();
        if (parent_count == 0) {
            if (event_offset == 0) return error.MissingParent;
            try parents.append(gpa, try resolve(oplog, received.items, event_offset - 1));
        } else {
            parent_count -= 1;
            while (parent_count > 0) : (parent_count -= 1) {
                const back = try event_reader.read();
                if (back == 0) {
                    const raw: agent.RawVersion = .{
                        .agent = try event_reader.read(),
                        .seq = try event_reader.readInt(agent.Seq),
                    };
                    try parents.append(gpa, oplog.cg.rawToLv(raw) orelse return error.MissingParent);
                } else {
                    if (back > event_offset) return error.MissingParent;
                    try parents.append(gpa, try resolve(oplog, received.items, event_offset - back));
                }
            }
        }

        const added = try oplog.cg.add(gpa, id, seq, seq + count, parents.items);
        const skip = if (added) |range| count - range.len() else count;

        // The runs partition the same events, so both are walked together.
        var consumed: u32 = 0;
        while (consumed < count) {
            const run = runs.items[run_idx];
            const take = @min(run.len - run_offset, count - consumed);
            const drop = if (consumed < skip) @min(take, skip - consumed) else 0;

            if (take > drop) {
                const at = run_offset + drop;
                try oplog.pushRemote(
                    added.?.start + (consumed + drop - skip),
                    take - drop,
                    run.kind,
                    run.posAt(at),
                    run.fwd,
                    run.textAt(content.payload, at, take - drop),
                );
            }

            run_offset += take;
            consumed += take;
            if (run_offset == run.len) {
                run_idx += 1;
                run_offset = 0;
            }
        }

        try received.append(gpa, .{ .offset = event_offset, .agent = id, .seq = seq, .count = count });
        event_offset += count;
    }
}

const Received = struct {
    offset: u64,
    agent: agent.Id,
    seq: agent.Seq,
    count: u32,
};

/// The local version of the message's `index`-th event, which the sender may
/// have pointed at as a parent.
fn resolve(oplog: *const oplog_mod.OpLog, received: []const Received, index: u64) !Lv {
    var low: usize = 0;
    var high: usize = received.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const span = received[mid];
        if (index < span.offset) {
            high = mid;
        } else if (index >= span.offset + span.count) {
            low = mid + 1;
        } else {
            const raw: agent.RawVersion = .{
                .agent = span.agent,
                .seq = span.seq + @as(agent.Seq, @intCast(index - span.offset)),
            };
            return oplog.cg.rawToLv(raw) orelse error.MissingParent;
        }
    }
    return error.MissingParent;
}

fn decodeRuns(gpa: std.mem.Allocator, ops: SectionData) !std.ArrayList(DecodedRun) {
    var runs: std.ArrayList(DecodedRun) = .empty;
    errdefer runs.deinit(gpa);
    try runs.ensureTotalCapacity(gpa, @intCast(ops.count));

    var reader: varint.Reader = .{ .bytes = ops.payload };
    var content_start: u32 = 0;
    var prev_pos: i64 = 0;

    var remaining = ops.count;
    while (remaining > 0) : (remaining -= 1) {
        const len = try reader.readInt(u32);
        const flags = (try reader.take(1))[0];
        const pos: u32 = @intCast(prev_pos + varint.unzigzag(try reader.read()));
        prev_pos = pos;

        const kind: oplog_mod.OpKind = @enumFromInt(flags & 1);
        try runs.append(gpa, .{
            .kind = kind,
            .fwd = flags & 2 != 0,
            .len = len,
            .pos = pos,
            .content_start = content_start,
        });
        if (kind == .insert) content_start += len;
    }

    return runs;
}

const testing = std.testing;

test "an oplog round trips through the wire format" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();

    try a.insert(0, "hola qué tal→");
    try a.backspace(15, 5);
    try a.delete(0, 2);
    try a.insert(0, "¿");

    const bytes = try a.serializeAll(testing.allocator);
    defer testing.allocator.free(bytes);

    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();
    try b.applyWire(bytes);

    try testing.expectEqual(a.len(), b.len());
    try testing.expectEqualSlices(Lv, a.cg.heads.items, b.cg.heads.items);
    try testing.expectEqual(a.runs.items.len, b.runs.items.len);

    var lv: Lv = 0;
    while (lv < a.len()) : (lv += 1) {
        const mine = a.opAt(lv);
        const theirs = b.opAt(lv);
        try testing.expectEqual(mine.kind, theirs.kind);
        try testing.expectEqual(mine.pos, theirs.pos);
        try testing.expectEqualStrings(mine.content, theirs.content);
        try testing.expectEqual(a.cg.lvToRaw(lv), b.cg.lvToRaw(lv));
    }

    // Applying the same message twice adds nothing.
    try b.applyWire(bytes);
    try testing.expectEqual(a.len(), b.len());
}

test "only the missing ranges travel" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "hello");
    const first = try a.serializeAll(testing.allocator);
    defer testing.allocator.free(first);
    try b.applyWire(first);

    try a.insert(5, "!");

    var theirs = try b.versionSummary(testing.allocator);
    defer theirs.deinit();

    const ranges = try a.rangesMissing(testing.allocator, theirs);
    defer testing.allocator.free(ranges);

    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(causal_graph.Range{ .start = 5, .end = 6 }, ranges[0]);

    const delta = try a.serialize(testing.allocator, ranges);
    defer testing.allocator.free(delta);
    try b.applyWire(delta);

    try testing.expectEqual(a.len(), b.len());
}

test "a parent we never saw is refused" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();

    try a.insert(0, "abc");
    try a.insert(3, "d");

    const tail = try a.serialize(testing.allocator, &.{.{ .start = 3, .end = 4 }});
    defer testing.allocator.free(tail);

    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try testing.expectError(error.MissingParent, b.applyWire(tail));
}
