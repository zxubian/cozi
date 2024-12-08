const Runnable = @This();
pub const RunProto = *const fn (ctx: *anyopaque) void;
pub const IntrusiveForwardListNode = @import("./containers/intrusive/forwardList.zig").Node;

runFn: RunProto,
ptr: *anyopaque,
intrusive_list_node: IntrusiveForwardListNode = .{},

pub inline fn run(self: *Runnable) void {
    self.runFn(self.ptr);
}
