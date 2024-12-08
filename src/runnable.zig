const Runnable = @This();
pub const RunProto = *const fn (runnable: *Runnable) void;
pub const IntrusiveForwardListNode = @import("./containers/intrusive/forwardList.zig").Node;

run: RunProto,
intrusive_list_node: IntrusiveForwardListNode = .{},
