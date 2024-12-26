//! Cooperatively-scheduled user-space thread.
const Fiber = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

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

const log = std.log.scoped(.fiber);

threadlocal var current_fiber: ?*Fiber = null;
coroutine: *Coroutine,
executor: Executor,
tick_runnable: Runnable,
owns_stack: bool = false,
name: [:0]const u8,
state: std.atomic.Value(u8) = .init(0),
awaiter: ?Awaiter,
suspend_illegal_scope_depth: Atomic(usize) = .init(0),

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
        .tick_runnable = fiber.runnable(),
        .name = @ptrCast(name[0..options.name.len]),
        .awaiter = null,
        .owns_stack = own_stack,
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
    if (self.inSuspendIllegalScope()) {
        std.debug.panic("Cannot suspend fiber while in \"suspend illegal\" scope.", .{});
    }
    log.debug("{s} about to suspend", .{self.name});
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

fn runTick(self: *Fiber) void {
    current_fiber = self;
    defer current_fiber = null;
    if (self.state.cmpxchgStrong(0, 1, .seq_cst, .seq_cst)) |_| {
        std.debug.panic("resuming twice!!", .{});
    }
    self.coroutine.@"resume"();
}

fn runTickAndMaybeTransfer(self: *Fiber) ?*Fiber {
    log.debug("{s} about to resume", .{self.name});
    self.runTick();
    log.debug("{s} returned from coroutine", .{self.name});
    if (self.coroutine.is_completed) {
        if (self.owns_stack) {
            log.debug("{s} deallocating stack", .{self.name});
            self.coroutine.deinit();
        }
        return null;
    }
    if (self.awaiter) |awaiter| {
        self.awaiter = null;
        const suspend_result = awaiter.awaitSuspend(self);
        switch (suspend_result) {
            .always_suspend => return null,
            .never_suspend => return self,
            .symmetric_transfer_next => |next| {
                // TODO: consider if self.resume is better
                self.scheduleSelf();
                return @alignCast(@ptrCast(next));
            },
        }
        return null;
    } else {
        std.debug.panic("Fiber coroutine suspended without setting fiber awaiter", .{});
    }
}

fn runChain(start: *Fiber) void {
    var maybe_next: ?*Fiber = start;
    while (maybe_next) |next| {
        maybe_next = next.runTickAndMaybeTransfer();
    }
}

fn run(ctx: *anyopaque) void {
    const self: *Fiber = @alignCast(@ptrCast(ctx));
    runChain(self);
}

fn runnable(fiber: *Fiber) Runnable {
    return Runnable{
        .runFn = run,
        .ptr = fiber,
    };
}

pub fn beginSuspendIllegalScope(self: *Fiber) void {
    _ = self.suspend_illegal_scope_depth.fetchAdd(1, .release);
}

pub fn endSuspendIllegalScope(self: *Fiber) void {
    _ = self.suspend_illegal_scope_depth.fetchSub(1, .release);
}

pub fn inSuspendIllegalScope(self: *Fiber) bool {
    return self.suspend_illegal_scope_depth.load(.acquire) > 0;
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
    ) Awaiter.AwaitSuspendResult {
        var fiber: *Fiber = @alignCast(@ptrCast(handle));
        fiber.scheduleSelf();
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }
    pub fn awaitResume(_: *anyopaque) void {}
};

test {
    _ = @import("./fiber/tests.zig");
    _ = @import("./fiber/sync.zig");
}
