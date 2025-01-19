const Runnable = @This();
pub const RunProto = *const fn (ctx: *anyopaque) void;
const Containers = @import("../containers/main.zig");

runFn: RunProto,
ptr: *anyopaque,
intrusive_list_node: Containers.Intrusive.Node = .{},

pub inline fn run(self: *Runnable) void {
    self.runFn(self.ptr);
}
