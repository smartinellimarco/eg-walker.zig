const std = @import("std");
const egwalker = @import("egwalker");
const rope = @import("rope");

const oplog_mod = egwalker.oplog;
const Branch = egwalker.Branch;
const Lv = egwalker.Lv;
const testing = std.testing;

// The crate has no text type, so the tests bring one and wire it up the same
// way a consumer does.
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

fn checkout(gpa: std.mem.Allocator, oplog: *const oplog_mod.OpLog) ![]u8 {
    var branch: Branch = .init(gpa);
    defer branch.deinit();

    var patch = try branch.merge(oplog);
    defer patch.deinit();

    var doc: rope.Text = try .init(gpa);
    defer doc.deinit();

    try egwalker.applyPatch(sinkOf(&doc), &patch);
    return doc.toBytes(gpa);
}

test "single agent typing reads back" {
    var oplog: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "hello");
    try oplog.insert(5, " world");
    try oplog.delete(0, 1);
    try oplog.insert(0, "H");

    const text = try checkout(testing.allocator, &oplog);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("Hello world", text);
}

test "concurrent inserts converge on both replicas" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "Helo");
    try b.mergeFrom(&a);

    try a.insert(3, "l");
    try b.insert(4, "!");

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const text_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(text_a);
    const text_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(text_b);

    try testing.expectEqualStrings("Hello!", text_a);
    try testing.expectEqualStrings("Hello!", text_b);
}

test "concurrent delete of the same character is not applied twice" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "abc");
    try b.mergeFrom(&a);

    try a.delete(1, 1);
    try b.delete(1, 1);

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const text_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(text_a);
    const text_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(text_b);

    try testing.expectEqualStrings("ac", text_a);
    try testing.expectEqualStrings("ac", text_b);
}

test "branch merges incrementally and emits transformed ops" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "hi");

    var branch: Branch = .init(testing.allocator);
    defer branch.deinit();

    var doc: rope.Text = try .init(testing.allocator);
    defer doc.deinit();

    var first = try branch.merge(&a);
    defer first.deinit();
    try egwalker.applyPatch(sinkOf(&doc), &first);
    try testing.expectEqual(@as(u32, 2), doc.len());

    try b.mergeFrom(&a);
    try b.insert(0, "oh ");
    try a.mergeFrom(&b);

    var second = try branch.merge(&a);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.len());
    try egwalker.applyPatch(sinkOf(&doc), &second);

    const out = try doc.toBytes(testing.allocator);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("oh hi", out);
}

test "backspacing one character at a time reads back" {
    var oplog: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "hello world");

    // Five separate events, the way a user actually holds backspace.
    var pos: u32 = 10;
    while (pos >= 6) : (pos -= 1) try oplog.delete(pos, 1);

    try testing.expectEqual(@as(usize, 2), oplog.runs.items.len);

    const text = try checkout(testing.allocator, &oplog);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("hello ", text);
}

test "a forward delete run after a single delete" {
    var oplog: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer oplog.deinit();

    try oplog.insert(0, "abcdef");
    try oplog.delete(1, 1);
    try oplog.delete(1, 2);

    const text = try checkout(testing.allocator, &oplog);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("aef", text);
}

test "a divergence that never closes stops growing state" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();

    try a.insert(0, "hello");
    const forked = a.version()[0];

    var branch: Branch = .{ .gpa = testing.allocator, .state_limit = 4 };
    defer branch.deinit();

    var first = try branch.merge(&a);
    first.deinit();

    // Two branches that never meet, so the version is never critical again.
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        _ = try a.insertAt(2, &.{forked}, 0, "x");
        _ = try a.insertAt(3, &.{forked}, 0, "y");

        var patch = try branch.merge(&a);
        patch.deinit();
    }

    try testing.expect(branch.live == null);

    const text = try checkout(testing.allocator, &a);
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 85), text.len);
}

test "a branch that already merged an entry checks the parents of the next one" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "he");
    try b.mergeFrom(&a);
    try b.insert(2, "X");

    // Agent 1 keeps typing, so its events stay one run-length encoded entry
    // while agent 2 forked off the middle of it.
    try a.insert(2, "llo");

    var branch: Branch = .init(testing.allocator);
    defer branch.deinit();

    var doc: rope.Text = try .init(testing.allocator);
    defer doc.deinit();

    var first = try branch.merge(&a);
    defer first.deinit();
    try egwalker.applyPatch(sinkOf(&doc), &first);

    try a.mergeFrom(&b);

    var second = try branch.merge(&a);
    defer second.deinit();
    try egwalker.applyPatch(sinkOf(&doc), &second);

    const out = try doc.toBytes(testing.allocator);
    defer testing.allocator.free(out);

    const whole = try checkout(testing.allocator, &a);
    defer testing.allocator.free(whole);

    try testing.expectEqualStrings(whole, out);
    try testing.expectEqualStrings("helloX", out);
}

test "concurrent backspace runs converge" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();
    var c: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 3 });
    defer c.deinit();

    try a.insert(0, "hello world hello world");
    try c.mergeFrom(&a);
    try c.insert(11, "ABCDE");
    try a.mergeFrom(&c);
    try b.mergeFrom(&a);

    // One holds backspace while the other types inside what it is erasing.
    try a.backspace(22, 12);
    try b.insert(20, "X");
    try b.insert(16, "Y");
    try b.insert(12, "Z");
    try b.backspace(4, 3);

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const from_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(from_a);
    const from_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(from_b);

    try testing.expectEqualStrings(from_a, from_b);
    try testing.expectEqualStrings("he worldZYXworld", from_a);
}

test "concurrent inserts inside one typed run converge" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();

    try a.insert(0, "hello");
    try b.mergeFrom(&a);

    // Both land in the middle of the same run, which has to split.
    try a.insert(2, "Y");
    try b.insert(2, "X");

    try a.mergeFrom(&b);
    try b.mergeFrom(&a);

    const from_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(from_a);
    const from_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(from_b);

    try testing.expectEqualStrings(from_a, from_b);
    try testing.expectEqualStrings("heYXllo", from_a);
}

test "a backspace run retreats by the id of the event being moved" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();
    var b: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 2 });
    defer b.deinit();
    var c: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 3 });
    defer c.deinit();

    try c.insert(0, "b");
    try c.insert(1, "x");
    try b.mergeFrom(&c);
    try c.delete(1, 1);
    try b.delete(1, 1);
    try a.mergeFrom(&b);
    try b.delete(0, 1);
    try a.insert(0, "g");
    try b.mergeFrom(&a);
    try b.insert(0, "g");

    try a.mergeFrom(&b);
    try a.mergeFrom(&c);
    try b.mergeFrom(&a);
    try c.mergeFrom(&a);

    // Short enough that the merge replays from a placeholder instead of from
    // the start, which is where the retreat runs over a whole backspace run.
    const from_a = try checkoutInSteps(testing.allocator, &a);
    defer testing.allocator.free(from_a);
    const from_b = try checkoutInSteps(testing.allocator, &b);
    defer testing.allocator.free(from_b);
    const from_c = try checkoutInSteps(testing.allocator, &c);
    defer testing.allocator.free(from_c);

    try testing.expectEqualStrings(from_a, from_b);
    try testing.expectEqualStrings(from_a, from_c);
    try testing.expectEqualStrings("gg", from_a);
}

fn checkoutInSteps(gpa: std.mem.Allocator, oplog: *const oplog_mod.OpLog) ![]u8 {
    var branch: Branch = .{ .gpa = gpa, .checkpoint_interval = 2 };
    defer branch.deinit();

    var patch = try branch.merge(oplog);
    defer patch.deinit();

    var doc: rope.Text = try .init(gpa);
    defer doc.deinit();
    try egwalker.applyPatch(sinkOf(&doc), &patch);

    return doc.toBytes(gpa);
}

test "an oplog saves and loads through a stream" {
    var a: oplog_mod.OpLog = .init(testing.allocator, .{ .agent = 1 });
    defer a.deinit();

    try a.insert(0, "hello world");
    try a.backspace(10, 5);
    try a.insert(6, "there");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try a.save(&out.writer);

    var reader: std.Io.Reader = .fixed(out.written());
    var b = try oplog_mod.OpLog.load(testing.allocator, .{ .agent = 1 }, &reader);
    defer b.deinit();

    try testing.expectEqual(a.len(), b.len());
    try testing.expectEqualSlices(Lv, a.version(), b.version());

    const from_a = try checkout(testing.allocator, &a);
    defer testing.allocator.free(from_a);
    const from_b = try checkout(testing.allocator, &b);
    defer testing.allocator.free(from_b);

    try testing.expectEqualStrings(from_a, from_b);
    try testing.expectEqualStrings("hello there", from_a);
}
