const std = @import("std");
const Fiber = @import("../fiber.zig");
const Awaiter = @This();
const Coroutine = @import("./coroutine.zig");

ptr: *anyopaque,

vtable: struct {
    await_suspend: *const fn (
        ctx: *anyopaque,
        coroutine_handle: *anyopaque,
    ) AwaitSuspendResult,
    await_resume: *const fn (ctx: *anyopaque) void,
    await_ready: *const fn (ctx: *anyopaque) bool,
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

pub inline fn awaitResume(self: *const Awaiter) void {
    return self.vtable.await_resume(self.ptr);
}

pub inline fn awaitReady(self: *const Awaiter) bool {
    return self.vtable.await_ready(self.ptr);
}
