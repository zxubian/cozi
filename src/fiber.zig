//! Cooperatively-scheduled user-space thread.
const Fiber = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Coroutine = @import("./coroutine.zig");
const Executor = @import("./executor.zig");
const Stack = @import("./stack.zig");
const Closure = @import("./closure.zig");
const Runnable = @import("./runnable.zig");
const Awaiter = @import("./fiber/awaiter.zig");
const YieldAwaiter = @import("./fiber/awaiters.zig").YieldAwaiter;

pub const Barrier = @import("./fiber/barrier.zig");
pub const Event = @import("./fiber/event.zig");
pub const Mutex = @import("./fiber/mutex.zig");
pub const WaitGroup = @import("./fiber/wait_group.zig");

const log = std.log.scoped(.fiber);

threadlocal var current_fiber: ?*Fiber = null;
coroutine: *Coroutine,
executor: Executor,
tick_runnable: Runnable,
owns_stack: bool = false,
name: [:0]const u8,
awaiter: ?*Awaiter = null,

var yield_awaiter = YieldAwaiter.awaiter();

pub const MAX_FIBER_NAME_LENGTH_BYTES = 100;

pub fn go(
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
    executor: Executor,
) !void {
    return goOptions(
        routine,
        args,
        allocator,
        executor,
        .{},
    );
}

pub const Options = struct {
    stack_size: usize = Coroutine.Stack.InitOptions.DEFAULT_STACK_SIZE_BYTES,
    name: [:0]const u8 = "Fiber",
};

pub fn goOptions(
    comptime routine: anytype,
    args: anytype,
    allocator: Allocator,
    executor: Executor,
    options: Options,
) !void {
    const stack = try Stack.initOptions(
        .{
            .size = options.stack_size,
        },
        allocator,
    );
    return goWithStack(
        routine,
        args,
        stack,
        executor,
        options,
        true,
    );
}

pub fn goWithStack(
    comptime routine: anytype,
    args: anytype,
    stack: Stack,
    executor: Executor,
    options: Options,
    comptime own_stack: bool,
) !void {
    var fixed_buffer_allocator = stack.bufferAllocator();
    const gpa = fixed_buffer_allocator.allocator();
    // place fiber & coroutine on coroutine stack
    // in order to avoid additional dynamic allocations
    var name = try gpa.alloc(u8, MAX_FIBER_NAME_LENGTH_BYTES);
    std.mem.copyForwards(u8, name, options.name);
    const fiber = try gpa.create(Fiber);
    const coroutine = try gpa.create(Coroutine);
    const routine_closure = try gpa.create(Closure.Impl(routine, false));
    routine_closure.*.init(args);
    // TODO: protect top of stack
    const padding = try gpa.alignedAlloc(u8, Stack.STACK_ALIGNMENT_BYTES, 1);
    _ = padding;
    coroutine.initNoAlloc(&routine_closure.*.runnable, stack);
    fiber.* = .{
        .coroutine = coroutine,
        .executor = executor,
        .tick_runnable = fiber.runnable(own_stack),
        .name = @ptrCast(name[0..options.name.len]),
        .awaiter = null,
    };
    fiber.scheduleSelf();
}

pub fn isInFiber() bool {
    return current_fiber != null;
}

pub fn current() ?*Fiber {
    return current_fiber;
}

pub fn yield() void {
    Fiber.@"suspend"(&yield_awaiter);
}

pub fn @"suspend"(awaiter: *Awaiter) void {
    if (current_fiber) |curr| {
        curr.suspend_(awaiter);
    } else {
        std.debug.panic("Cannot call Fiber.suspend when from outside of a Fiber.", .{});
    }
}

fn suspend_(self: *Fiber, awaiter: *Awaiter) void {
    log.info("{s} about to suspend", .{self.name});
    self.awaiter = awaiter;
    self.coroutine.@"suspend"();
}

pub fn scheduleSelf(self: *Fiber) void {
    self.executor.submitRunnable(&self.tick_runnable);
}

fn runnable(fiber: *Fiber, comptime owns_stack: bool) Runnable {
    const tick_fn = struct {
        pub fn tick(ctx: *anyopaque) void {
            const self: *Fiber = @alignCast(@ptrCast(ctx));
            const old_ctx = current_fiber;
            current_fiber = self;
            log.info("{s} about to resume", .{self.name});
            self.coroutine.@"resume"();
            if (self.coroutine.is_completed) {
                log.info("{s} completed", .{self.name});
                if (owns_stack) {
                    log.info("{s} deallocating stack", .{self.name});
                    self.coroutine.deinit();
                }
            } else {
                if (self.awaiter) |awaiter| {
                    self.awaiter = null;
                    awaiter.@"await"(self);
                }
            }
            current_fiber = old_ctx;
        }
    }.tick;
    return Runnable{
        .runFn = tick_fn,
        .ptr = fiber,
    };
}

test {
    _ = @import("./fiber/tests.zig");

    _ = @import("./fiber/barrier.zig");
    _ = @import("./fiber/event.zig");
    _ = @import("./fiber/mutex.zig");
    _ = @import("./fiber/wait_group.zig");
}
