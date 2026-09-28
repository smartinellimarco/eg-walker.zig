const std = @import("std");

pub const agent = @import("agent.zig");
pub const causal_graph = @import("causal_graph.zig");
pub const oplog = @import("oplog.zig");
pub const walker = @import("walker.zig");
pub const edit_context = @import("edit_context.zig");
pub const item_tree = @import("item_tree.zig");
pub const integrate = @import("integrate.zig");
pub const branch = @import("branch.zig");
pub const anchor = @import("anchor.zig");
pub const sink = @import("sink.zig");
pub const encoding = @import("encoding.zig");

pub const AgentId = agent.Id;
pub const Lv = causal_graph.Lv;
pub const OpLog = oplog.OpLog;
pub const Patch = walker.Patch;
pub const TransformedOp = walker.TransformedOp;
pub const Branch = branch.Branch;
pub const Sink = sink.Sink;
pub const Bias = anchor.Bias;
pub const mapCursor = anchor.map;
pub const applyPatch = branch.apply;

// One level of refAllDecls stops at the module structs, and a public function
// nobody calls never gets compiled.
test {
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const field = @field(@This(), decl.name);
        if (@TypeOf(field) == type and @typeInfo(field) == .@"struct") std.testing.refAllDecls(field);
    }
}
