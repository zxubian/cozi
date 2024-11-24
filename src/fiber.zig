threadlocal var current_fiber: ?*Fiber = null;
coroutine: *Coroutine,
executor: *Executor,
allocator: Allocator,

pub fn go(
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
    executor: *Executor,
) !*Fiber {
    const coroutine = try allocator.create(Coroutine);
    const fiber = try allocator.create(Fiber);
    fiber.* = .{
        .coroutine = coroutine,
        .executor = executor,
        .allocator = allocator,
    };
    try coroutine.init(routine, args, allocator);
    fiber.scheduleSelf();
    return fiber;
}

pub fn isInFiber() bool {
    return current_fiber != null;
}

pub fn yield() void {
    if (current_fiber) |ctx| {
        ctx._yield();
    } else {
        std.debug.panic("Cannot call Fiber.yield when from outside of a Fiber.", .{});
    }
}

fn _yield(this: *Fiber) void {
    this.coroutine.@"suspend"();
}

fn scheduleSelf(this: *Fiber) void {
    this.executor.submit(tick, .{this}, this.allocator);
}

fn deinit(this: *Fiber) void {
    this.coroutine.deinit();
    this.allocator.destroy(this.coroutine);
    this.allocator.destroy(this);
}

fn tick(this: *Fiber) void {
    const old_ctx = current_fiber;
    current_fiber = this;
    this.coroutine.@"resume"();
    if (this.coroutine.is_completed) {
        this.deinit();
    } else {
        this.scheduleSelf();
    }
    current_fiber = old_ctx;
}

test {
    _ = @import("./fiber/tests.zig");
}

const Fiber = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Coroutine = @import("./coroutine.zig");
const Executor = @import("./executors.zig").Executor;
