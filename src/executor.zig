const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Runnable = @import("./runnable.zig");
const Closure = @import("./closure.zig");

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
    args: anytype,
    allocator: Allocator,
) void {
    // No way to recover here. Just crash.
    // Don't want to propagate the error up.
    const closure = Closure.init(func, args, allocator) catch |e| std.debug.panic(
        "Failed to allocate closure in {s}: {}",
        .{ @typeName(Executor), e },
    );
    closure.* = .{
        .arguments = args,
        .runnable = .{
            .runFn = @TypeOf(closure.*).run,
            .ptr = closure,
        },
        .allocator = allocator,
    };
    self.vtable.submit(self.ptr, &closure.runnable);
}
