//! Cooperatively-scheduled user-space thread.
const Fiber = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const fault = @import("../fault/root.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const Coroutine = @import("../coroutine/root.zig");
const executors = @import("../executors/root.zig");
const Executor = executors.Executor;
const Core = @import("../core/root.zig");
const Closure = Core.Closure;
const Runnable = Core.Runnable;
const Stack = Core.Stack;
const GenericAwait = @import("../await/root.zig");
const Await = GenericAwait.@"await";
const Awaiter = GenericAwait.Awaiter;

const Sync = @import("./sync.zig");
pub const Barrier = Sync.Barrier;
const Channel_ = @import("./channel/root.zig");
pub const Channel = Channel_.Channel;
pub const select = Channel_.select;
pub const Event = Sync.Event;
pub const Mutex = Sync.Mutex;
pub const Strand = Sync.Strand;
pub const WaitGroup = Sync.WaitGroup;

const log = std.log.scoped(.fiber);

threadlocal var current_fiber: ?*Fiber = null;
coroutine: *Coroutine,
executor: Executor,
tick_runnable: Runnable,
name: [:0]const u8,
state: stdlike.atomic.Value(u8) = .init(0),
awaiter: ?Awaiter,
suspend_illegal_scope_depth: Atomic(usize) = .init(0),

pub const MAX_FIBER_NAME_LENGTH_BYTES = 100;
pub const DEFAULT_NAME = "Fiber";

/// Create new fiber and schedule it for execution on `executor`.
/// Fiber will call `routine(args)` when executed.
/// `allocator` will be used to allocate stack for Fiber execution.
pub fn go(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    allocator: Allocator,
    executor: Executor,
) !void {
    try goOptions(
        routine,
        args,
        allocator,
        executor,
        .{},
    );
}

pub fn goWithName(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    allocator: Allocator,
    executor: Executor,
    name: [:0]const u8,
) !void {
    return goOptions(
        routine,
        args,
        allocator,
        executor,
        .{
            .fiber = .{
                .name = name,
            },
        },
    );
}

pub fn goWithNameFmt(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    allocator: Allocator,
    executor: Executor,
    comptime name_fmt: [:0]const u8,
    name_fmt_args: anytype,
) !void {
    var name_buf: [MAX_FIBER_NAME_LENGTH_BYTES]u8 = undefined;
    return goWithName(
        routine,
        args,
        allocator,
        executor,
        try std.fmt.bufPrintZ(&name_buf, name_fmt, name_fmt_args),
    );
}

pub const Options = struct {
    stack_size: usize = Stack.DEFAULT_SIZE_BYTES,
    fiber: FiberOptions = .{},

    pub const FiberOptions = struct {
        name: [:0]const u8 = DEFAULT_NAME,
    };
};

/// Create new fiber with custom options and schedule it for execution on `executor`.
/// Fiber will call `routine(args)` when executed.
/// `allocator` will be used to allocate stack for Fiber execution.
pub fn goOptions(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    allocator: Allocator,
    executor: Executor,
    options: Options,
) !void {
    const fiber = try initOptions(
        routine,
        args,
        allocator,
        executor,
        options,
    );
    fiber.scheduleSelf();
}

/// Create new fiber and schedule it for execution.
/// Fiber will call routine(args) when executed.
/// Any additional allocations necessary for fiber
/// will be placed on the pre-provided stack.
pub fn goWithStack(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    stack: Stack,
    executor: Executor,
    options: Options.FiberOptions,
) !void {
    const fiber = try initWithStack(
        routine,
        args,
        stack,
        executor,
        options,
    );
    fiber.scheduleSelf();
}

pub fn initOptions(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    allocator: Allocator,
    executor: Executor,
    options: Options,
) !*Fiber {
    // place fiber & coroutine on coroutine stack
    // in order to avoid additional dynamic allocations
    const stack = try Stack.Managed.initOptions(
        allocator,
        .{ .size = options.stack_size },
    );
    var fixed_buffer_allocator = stack.bufferAllocator();
    const arena = fixed_buffer_allocator.allocator();
    const store_allocator_ptr = try arena.create(Allocator);
    store_allocator_ptr.* = allocator;
    const coroutine = try Coroutine.initOnStack(routine, args, stack.raw, arena);
    return try init(coroutine, executor, options.fiber, arena, true);
}

pub fn initWithStack(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    stack: Stack,
    executor: Executor,
    options: Options.FiberOptions,
) !*Fiber {
    // place fiber & coroutine on coroutine stack
    // in order to avoid additional dynamic allocations
    var fixed_buffer_allocator = stack.bufferAllocator();
    const arena = fixed_buffer_allocator.allocator();
    const coroutine = try Coroutine.initOnStack(routine, args, stack, arena);
    return try init(coroutine, executor, options, arena, false);
}

pub fn init(
    coroutine: *Coroutine,
    executor: Executor,
    options: Options.FiberOptions,
    stack_arena: Allocator,
    comptime owns_stack: bool,
) !*Fiber {
    const name = try copyNameToStack(options.name, stack_arena);
    const fiber = try stack_arena.create(Fiber);
    fiber.* = .{
        .coroutine = coroutine,
        .executor = executor,
        .tick_runnable = fiber.runnable(owns_stack),
        .name = @ptrCast(name[0..options.name.len]),
        .awaiter = null,
    };
    return fiber;
}

fn copyNameToStack(name: []const u8, stack_arena: Allocator) ![]const u8 {
    const result = try stack_arena.alloc(u8, MAX_FIBER_NAME_LENGTH_BYTES);
    std.mem.copyForwards(u8, result, name);
    return result;
}

pub fn isInFiber() bool {
    return current_fiber != null;
}

pub fn current() ?*Fiber {
    return current_fiber;
}

/// Suspend current fiber, and reschedule it for execution on the same executor.
pub fn yield() void {
    if (current_fiber) |curr| {
        curr.yield_();
    } else {
        std.debug.panic("Must use Fiber.yield only when executing on a fiber", .{});
    }
}

fn yield_(self: *Fiber) void {
    log.debug("{s} about to yield", .{self.name});
    var yield_awaiter: YieldAwaiter = .{};
    Await(&yield_awaiter);
    log.debug("{s}: resume from yield", .{self.name});
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
    log.debug("{s} getting scheduled", .{self.name});
    self.executor.submitRunnable(&self.tick_runnable);
}

/// Suspend the current fiber, and reschedule it on new_executor
pub fn switchTo(new_executor: Executor) void {
    if (current_fiber) |curr| {
        curr.switchTo_(new_executor);
    } else {
        std.debug.panic("Must use Fiber.switchTo only when executing on a fiber", .{});
    }
}

/// Suspend self, and schedule it on new_executor
fn switchTo_(self: *Fiber, new_executor: Executor) void {
    var switch_awaiter: SwitchAwaiter = .{ .executor = new_executor };
    log.debug("{s} about to switch executors: {*} -> {*}", .{ self.name, self.executor.ptr, new_executor.ptr });
    Await(&switch_awaiter);
}

pub inline fn runTickAndMaybeTransfer(self: *Fiber, comptime owns_stack: bool) ?*Fiber {
    return RunFunctions(owns_stack).runTickAndMaybeTransfer(self);
}

fn RunFunctions(comptime owns_stack: bool) type {
    return struct {
        fn runTickAndMaybeTransfer(self: *Fiber) ?*Fiber {
            log.debug("{s} about to resume", .{self.name});
            self.runTick();
            log.debug("{s} returned from coroutine", .{self.name});
            if (self.coroutine.is_completed) {
                if (owns_stack) {
                    self.getManagedStack().deinit();
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
                        const next_fiber: *Fiber = @alignCast(@ptrCast(next));
                        // TODO: consider if self.resume() or self.scheduleSelf() is better
                        log.debug("Got request for symmetric transfer: {s} -> {s}", .{ self.name, next_fiber.name });
                        log.debug("{s} Resuming self first.", .{self.name});
                        self.@"resume"();
                        log.debug("Symmetric transfer: -> {s}", .{next_fiber.name});
                        return next_fiber;
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
                maybe_next = next.runTickAndMaybeTransfer(owns_stack);
            }
        }

        fn run(ctx: *anyopaque) void {
            const self: *Fiber = @alignCast(@ptrCast(ctx));
            runChain(self);
        }
    };
}

fn runnable(fiber: *Fiber, comptime owns_stack: bool) Runnable {
    return Runnable{
        .runFn = RunFunctions(owns_stack).run,
        .ptr = fiber,
    };
}

fn getManagedStack(self: *Fiber) Stack.Managed {
    const stack = self.coroutine.stack;
    const stack_base = stack.base();
    const offset = std.mem.alignPointerOffset(
        stack_base,
        @sizeOf(Allocator),
    ).?;
    const allocator = std.mem.bytesToValue(
        Allocator,
        stack.slice[offset .. offset + @sizeOf(Allocator)],
    );
    return Stack.Managed{
        .raw = stack,
        .allocator = allocator,
    };
}

fn runTick(self: *Fiber) void {
    current_fiber = self;
    defer current_fiber = null;
    if (self.state.cmpxchgStrong(0, 1, .seq_cst, .seq_cst)) |_| {
        std.debug.panic("{s} resuming twice!!", .{self.name});
    }
    self.coroutine.@"resume"();
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
    // --- type-erased awaiter interface ---
    pub fn awaitSuspend(
        _: *anyopaque,
        handle: *anyopaque,
    ) Awaiter.AwaitSuspendResult {
        var fiber: *Fiber = @alignCast(@ptrCast(handle));
        fiber.scheduleSelf();
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }

    pub fn awaiter(self: *YieldAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{ .await_suspend = awaitSuspend },
        };
    }

    /// --- comptime awaiter interface ---
    pub fn awaitReady(_: *YieldAwaiter) bool {
        return false;
    }

    pub fn awaitResume(_: *YieldAwaiter, _: bool) void {}
};

const SwitchAwaiter = struct {
    executor: Executor,
    // --- type-erased awaiter interface ---
    pub fn awaitSuspend(
        ctx: *anyopaque,
        handle: *anyopaque,
    ) Awaiter.AwaitSuspendResult {
        const self: *@This() = @alignCast(@ptrCast(ctx));
        var fiber: *Fiber = @alignCast(@ptrCast(handle));
        fiber.executor = self.executor;
        fiber.scheduleSelf();
        return .always_suspend;
    }

    pub fn awaiter(self: *SwitchAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{ .await_suspend = awaitSuspend },
        };
    }

    /// --- comptime awaiter interface ---
    pub fn awaitReady(_: *SwitchAwaiter) bool {
        return false;
    }

    pub fn awaitResume(_: *SwitchAwaiter, _: bool) void {}
};

test {
    _ = @import("./tests.zig");
    _ = Sync;
    _ = Channel;
}
