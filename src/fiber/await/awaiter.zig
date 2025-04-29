//! Type-erased awaiter interface
//! See `cozi.fiber.@"await".@"await"` for usage.
//! See `cozi.fiber.YieldAwaiter` for example implementation.
const std = @import("std");
const Awaiter = @This();
const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;

ptr: *anyopaque,

vtable: struct {
    await_suspend: *const fn (
        ctx: *anyopaque,
        coroutine_handle: *anyopaque,
    ) AwaitSuspendResult,
},

pub const AwaitSuspendResult = union(enum(usize)) {
    /// This fiber is not ready to be resumed.
    /// Proceed with suspending and give control back to the scheduler.
    always_suspend: void,
    /// This fiber is ready to be resumed.
    /// Give control back to this fiber immediately, without going through the scheduler.
    never_suspend: void,
    /// Control should be transfered to another fiber pointed to by the opaque pointer,
    /// without going through the scheduler.
    symmetric_transfer_next: ?*anyopaque,
};

/// Called by generic `await` algorithm on suspended coroutine/fiber.
/// Returns a `AwaitSuspendResult` indicating whether:
/// a) this fiber must be immediately resumed
/// b) this fiber will continue in suspended state
/// c) control should be transfered to another fiber without going through the scheduler
pub inline fn awaitSuspend(
    self: *const Awaiter,
    coroutine_handle: *anyopaque,
) AwaitSuspendResult {
    return self.vtable.await_suspend(
        self.ptr,
        coroutine_handle,
    );
}
