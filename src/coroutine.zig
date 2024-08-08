//! Stackfull coroutine
const std = @import("std");
const log = std.log.scoped(.coroutine);
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Runnable = @import("./runnable.zig");
const ExecutionContext = @import("./coroutine/executionContext.zig");
const Trampoline = ExecutionContext.Trampoline;

pub const Stack = ExecutionContext.Stack;

const Coroutine = @This();

routine: *Runnable = undefined,
previous_context: ExecutionContext = undefined,
stack: Stack = undefined,
execution_context: ExecutionContext = undefined,
is_completed: bool = false,

const DEFAULT_STACK_SIZE_BYTES = 64 * 1024;

pub fn init(
    self: *Coroutine,
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
) !void {
    return self.initWithStackSize(
        DEFAULT_STACK_SIZE_BYTES,
        routine,
        args,
        allocator,
    );
}

pub fn initWithStackSize(
    self: *Coroutine,
    stack_size: usize,
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
) !void {
    const stack = try Stack.init(stack_size, allocator);
    return initWithStack(
        self,
        stack,
        routine,
        args,
        allocator,
    );
}

pub fn initWithStack(
    self: *Coroutine,
    stack: Stack,
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
) !void {
    const routine_runnable = try initClosureForRoutine(
        routine,
        args,
        allocator,
    );
    self.* = .{
        .stack = stack,
        .routine = routine_runnable,
    };
    self.execution_context.init(
        stack,
        self.trampoline(),
    );
}

fn initClosureForRoutine(
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
) !*Runnable {
    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        allocator: Allocator,
        runnable: Runnable,

        fn runFn(runnable: *Runnable) void {
            const closure: *@This() = @fieldParentPtr("runnable", runnable);
            @call(.auto, routine, closure.arguments);
            closure.allocator.destroy(closure);
        }
    };
    const closure = try allocator.create(Closure);
    closure.* = .{
        .arguments = args,
        .runnable = .{
            .runFn = Closure.runFn,
        },
        .allocator = allocator,
    };
    return &closure.runnable;
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
    self.routine.runFn(self.routine);
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
