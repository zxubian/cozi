//! Stackfull coroutine
const std = @import("std");
const log = std.log.scoped(.coroutine);
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Runnable = @import("./runnable.zig");
const Closure = @import("./closure.zig");
const ExecutionContext = @import("./coroutine/executionContext.zig");
const Trampoline = ExecutionContext.Trampoline;

pub const Stack = ExecutionContext.Stack;

const Coroutine = @This();

runnable: *Runnable = undefined,
previous_context: ExecutionContext = .{},
stack: Stack = undefined,
execution_context: ExecutionContext = .{},
is_completed: bool = false,

pub fn init(
    self: *Coroutine,
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
) !void {
    const stack = try Stack.init(allocator);
    const closure = try Closure.init(
        routine,
        args,
        allocator,
    );
    return self.initNoAlloc(
        &closure.*.runnable,
        stack,
    );
}

pub fn initNoAlloc(
    self: *Coroutine,
    runnable: *Runnable,
    stack: Stack,
) void {
    self.* = .{
        .runnable = runnable,
        .stack = stack,
    };
    self.execution_context.init(
        stack,
        self.trampoline(),
    );
}

fn trampoline(self: *Coroutine) Trampoline {
    return Trampoline{
        .ptr = self,
        .vtable = &.{
            .run = run,
        },
    };
}

fn run(ctx: *anyopaque) noreturn {
    var self: *Coroutine = @ptrCast(@alignCast(ctx));
    self.runnable.run();
    self.complete();
}

fn complete(self: *Coroutine) noreturn {
    self.is_completed = true;
    self.execution_context.exitTo(&self.previous_context);
}

pub fn deinit(self: *Coroutine) void {
    assert(self.is_completed);
    self.stack.deinit();
}

pub fn @"resume"(self: *Coroutine) void {
    self.previous_context.switchTo(&self.execution_context);
}

pub fn @"suspend"(self: *Coroutine) void {
    self.execution_context.switchTo(&self.previous_context);
}

test {
    _ = @import("./coroutine/tests.zig");
}
