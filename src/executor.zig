const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Runnable = @import("./runnable.zig");
const Closure = @import("./closure.zig").Closure;

const Executor = @This();

ptr: *anyopaque,
vtable: Vtable,

const Vtable = struct {
    submit: *const fn (ctx: *anyopaque, *Runnable) void,
};

pub inline fn submitRunnable(self: *const Executor, runnable: *Runnable) void {
    self.vtable.submit(self.ptr, runnable);
}

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
