const std = @import("std");
const Awaiter = @This();

ptr: *anyopaque,

vtable: struct {
    await_suspend: *const fn (
        ctx: *anyopaque,
        coroutine_handle: *anyopaque,
    ) AwaitSuspendResult,
},

pub const AwaitSuspendResult = union(enum(usize)) {
    always_suspend: void,
    never_suspend: void,
    symmetric_transfer_next: ?*anyopaque,
};

pub inline fn awaitSuspend(
    self: *const Awaiter,
    coroutine_handle: *anyopaque,
) AwaitSuspendResult {
    return self.vtable.await_suspend(
        self.ptr,
        coroutine_handle,
    );
}
