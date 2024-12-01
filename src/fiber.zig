//! Cooperatively-scheduled user-space thread.
const Fiber = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Coroutine = @import("./coroutine.zig");
const Executor = @import("./executors.zig").Executor;

threadlocal var current_fiber: ?*Fiber = null;
coroutine: *Coroutine,
executor: Executor,
allocator: Allocator,

pub fn go(
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
    executor: Executor,
) !void {
    const coroutine = try allocator.create(Coroutine);
    const fiber = try allocator.create(Fiber);
    fiber.* = .{
        .coroutine = coroutine,
        .executor = executor,
        .allocator = allocator,
    };
    try coroutine.init(routine, args, allocator);
    fiber.scheduleSelf();
}

pub fn isInFiber() bool {
    return current_fiber != null;
}

pub fn current() ?*const Fiber {
    return current_fiber;
}

pub fn yield() void {
    if (current_fiber) |curr| {
        curr._yield();
    } else {
        std.debug.panic("Cannot call Fiber.yield when from outside of a Fiber.", .{});
    }
}

fn _yield(self: *Fiber) void {
    self.coroutine.@"suspend"();
}

fn scheduleSelf(self: *Fiber) void {
    self.executor.submit(tick, .{self}, self.allocator);
}

fn deinit(self: *Fiber) void {
    self.coroutine.deinit();
    self.allocator.destroy(self.coroutine);
    self.allocator.destroy(self);
}

fn tick(self: *Fiber) void {
    const old_ctx = current_fiber;
    current_fiber = self;
    self.coroutine.@"resume"();
    if (self.coroutine.is_completed) {
        self.deinit();
    } else {
        self.scheduleSelf();
    }
    current_fiber = old_ctx;
}

test {
    _ = @import("./fiber/tests.zig");
}
