//! Executor is a type-erased interface representing an abstract task queue.
//! It is to asynchronous execution what Allocator is to memory management.
//! Executor allows users to submit `Runnable`s (an abstract representation a task)
//! for eventual execution.
//! Correct user programs cannot depend on the timing or order of execution of runnables,
//! and cannot assumptions about which thread will execute the runnable.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Core = @import("../core/root.zig");
const Runnable = Core.Runnable;
const Closure = Core.Closure;

const Executor = @This();

/// type-erased pointer to Executor implementation
/// NOTE: may be `undefined`
ptr: *anyopaque,
vtable: Vtable,

pub const Vtable = struct {
    submit: *const fn (ctx: *anyopaque, *Runnable) void,
};

/// Submit a `runnable`.
/// Guarantee: the `runnable` will be executed eventually on some thread.
pub inline fn submitRunnable(self: *const Executor, runnable: *Runnable) void {
    self.vtable.submit(self.ptr, runnable);
}

/// Allocate a Closure wrapping the provided arguments `args`,
/// and the function pointer `func`.
/// Then submit the closure to the executor for eventual execution.
/// The closure will be automatically deallocated once `func` exits.
/// For manual memory management, use `Executor.submitRunnable`.
/// Guarantee: same as `submitRunnable`.
pub inline fn submit(
    self: *const Executor,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
    allocator: Allocator,
) void {
    // No way to recover here. Just crash.
    // Don't want to propagate the error up.
    const closure = Closure(func).Managed.init(args, allocator) catch |e| std.debug.panic(
        "Failed to allocate closure in {s}: {}",
        .{ @typeName(Executor), e },
    );
    self.vtable.submit(self.ptr, closure.runnable());
}
