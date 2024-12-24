//! Cooperatively-scheduled user-space thread.
const Fiber = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Coroutine = @import("./coroutine.zig");
const Executor = @import("./executor.zig");
const Stack = @import("./stack.zig");
const Closure = @import("./closure.zig");
const Runnable = @import("./runnable.zig");
const Await = @import("./await.zig").@"await";
const Awaiter = @import("./awaiter.zig");

const Sync = @import("./fiber/sync.zig");
pub const Barrier = Sync.Barrier;
pub const Event = Sync.Event;
pub const Mutex = Sync.Mutex;
pub const Strand = Sync.Strand;
pub const WaitGroup = Sync.WaitGroup;
pub const SuspendIllegalScope = @import("./fiber/suspendIllegalScope.zig");

const log = std.log.scoped(.fiber);

threadlocal var current_fiber: ?*Fiber = null;
coroutine: *Coroutine,
executor: Executor,
tick_runnable: Runnable,
owns_stack: bool = false,
name: [:0]const u8,
suspend_illegal_scope: ?*SuspendIllegalScope = null,
state: std.atomic.Value(u8) = .init(0),
awaiter: ?Awaiter,

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
    if (current_fiber) |curr| {
        curr.yield_();
    } else {
        std.debug.panic("Must use Fiber.Yield only when executing inside of fiber", .{});
    }
}

fn yield_(_: *Fiber) void {
    var yield_awaiter: YieldAwaiter = .{};
    Await(&yield_awaiter);
}

pub fn @"suspend"(self: *Fiber, awaiter: Awaiter) void {
    if (self.suspend_illegal_scope) |scope| {
        std.debug.panic(
            "Cannot suspend fiber while in \"suspend illegal\" scope {*}",
            .{scope},
        );
    }
    log.info("{s} about to suspend", .{self.name});
    if (self.state.cmpxchgStrong(1, 0, .seq_cst, .seq_cst)) |_| {
        std.debug.panic("suspending twice!!", .{});
    }
    self.awaiter = awaiter;
    self.coroutine.@"suspend"();
}

pub fn @"resume"(self: *Fiber) void {
    self.tick_runnable.run();
}

pub fn scheduleSelf(self: *Fiber) void {
    self.executor.submitRunnable(&self.tick_runnable);
}

fn runnable(fiber: *Fiber, comptime owns_stack: bool) Runnable {
    const tick_fn = struct {
        pub fn tick(ctx: *anyopaque) void {
            var self: *Fiber = @alignCast(@ptrCast(ctx));
            const old_ctx = current_fiber;
            current_fiber = self;
            log.info("{s} about to resume", .{self.name});
            if (self.state.cmpxchgStrong(0, 1, .seq_cst, .seq_cst)) |_| {
                std.debug.panic("resuming twice!!", .{});
            }
            while (true) {
                self.coroutine.@"resume"();
                if (self.coroutine.is_completed) {
                    log.info("{s} completed", .{self.name});
                    if (owns_stack) {
                        log.info("{s} deallocating stack", .{self.name});
                        self.coroutine.deinit();
                    }
                    break;
                } else {
                    if (self.awaiter) |*awaiter| {
                        if (!awaiter.awaitSuspend(self)) {
                            break;
                        }
                    }
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

const YieldAwaiter = struct {
    pub fn awaiter(self: *YieldAwaiter) Awaiter {
        return Awaiter{ .ptr = self, .vtable = .{
            .await_ready = awaitReady,
            .await_suspend = awaitSuspend,
            .await_resume = awaitResume,
        } };
    }
    pub fn awaitReady(_: *anyopaque) bool {
        return false;
    }
    pub fn awaitSuspend(
        _: *anyopaque,
        handle: *anyopaque,
    ) bool {
        var fiber: *Fiber = @alignCast(@ptrCast(handle));
        fiber.scheduleSelf();
        return false;
    }
    pub fn awaitResume(_: *anyopaque) void {}
};

test {
    _ = @import("./fiber/tests.zig");
}
