const std = @import("std");

pub const varint = @import("encoding/varint.zig");
pub const wire = @import("encoding/wire.zig");
pub const sync = @import("encoding/sync.zig");

test {
    std.testing.refAllDecls(@This());
}
