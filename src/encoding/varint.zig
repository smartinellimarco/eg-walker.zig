const std = @import("std");

pub fn encode(buf: []u8, value: u64) usize {
    var rest = value;
    var i: usize = 0;
    while (true) {
        const byte: u8 = @truncate(rest & 0x7f);
        rest >>= 7;
        if (rest == 0) {
            buf[i] = byte;
            return i + 1;
        }
        buf[i] = byte | 0x80;
        i += 1;
    }
}

pub fn decode(buf: []const u8) !struct { value: u64, len: usize } {
    var value: u64 = 0;
    var shift: u6 = 0;
    for (buf, 0..) |byte, i| {
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return .{ .value = value, .len = i + 1 };
        shift = std.math.add(u6, shift, 7) catch return error.Overflow;
    }
    return error.Truncated;
}

// Deltas are signed (cursor jumps backwards), zigzag keeps small ones one byte.
pub fn zigzag(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> 63));
}

pub fn unzigzag(value: u64) i64 {
    const signed: i64 = @bitCast(value >> 1);
    return signed ^ -@as(i64, @intCast(value & 1));
}

test "roundtrip across byte boundaries" {
    var buf: [10]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 300, 16383, 16384, std.math.maxInt(u64) }) |value| {
        const len = encode(&buf, value);
        const got = try decode(buf[0..len]);
        try std.testing.expectEqual(value, got.value);
        try std.testing.expectEqual(len, got.len);
    }
}

test "zigzag roundtrip" {
    for ([_]i64{ 0, -1, 1, -64, 63, std.math.minInt(i64), std.math.maxInt(i64) }) |value| {
        try std.testing.expectEqual(value, unzigzag(zigzag(value)));
    }
}

test "truncated input is an error" {
    try std.testing.expectError(error.Truncated, decode(&[_]u8{0x80}));
}

pub fn write(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var buf: [10]u8 = undefined;
    const len = encode(&buf, value);
    try out.appendSlice(gpa, buf[0..len]);
}

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn read(self: *Reader) !u64 {
        const got = try decode(self.bytes[self.pos..]);
        self.pos += got.len;
        return got.value;
    }

    pub fn readInt(self: *Reader, comptime T: type) !T {
        return std.math.cast(T, try self.read()) orelse error.Overflow;
    }

    pub fn take(self: *Reader, len: usize) ![]const u8 {
        if (self.pos + len > self.bytes.len) return error.Truncated;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    pub fn atEnd(self: Reader) bool {
        return self.pos == self.bytes.len;
    }
};

test "reader walks a stream of varints" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try write(std.testing.allocator, &out, 1);
    try write(std.testing.allocator, &out, 300);
    try out.appendSlice(std.testing.allocator, "hi");

    var reader: Reader = .{ .bytes = out.items };
    try std.testing.expectEqual(@as(u64, 1), try reader.read());
    try std.testing.expectEqual(@as(u64, 300), try reader.read());
    try std.testing.expectEqualStrings("hi", try reader.take(2));
    try std.testing.expect(reader.atEnd());
}
