const std = @import("std");

pub const Error = error{OutOfMemory};

/// Where a patch lands. The crate never has to know what holds the text: the
/// included rope, an editor's buffer, a plain array in a test.
pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Positions are characters, and the text is utf-8.
        insert: *const fn (ptr: *anyopaque, pos: u32, text: []const u8) Error!void,
        delete: *const fn (ptr: *anyopaque, pos: u32, count: u32) void,
    };

    pub fn insert(self: Sink, pos: u32, text: []const u8) Error!void {
        return self.vtable.insert(self.ptr, pos, text);
    }

    pub fn delete(self: Sink, pos: u32, count: u32) void {
        self.vtable.delete(self.ptr, pos, count);
    }
};
