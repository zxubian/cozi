//! Cooperatively-scheduled user-space thread.
const Fiber = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Coroutine = @import("./coroutine.zig");
const Executor = @import("./executor.zig");
const Stack = @import("./stack.zig");
const Closure = @import("./closure.zig");
const Runnable = @import("./runnable.zig");
const log = std.log.scoped(.fiber);

threadlocal var current_fiber: ?*Fiber = null;
coroutine: *Coroutine,
executor: Executor,
tick_runnable: Runnable,
owns_stack: bool = false,
name: [:0]const u8,
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
    };
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
    self.executor.submitRunnable(&self.tick_runnable);
}

fn runnable(fiber: *Fiber, comptime owns_stack: bool) Runnable {
    const tick_fn = struct {
        pub fn tick(ctx: *anyopaque) void {
            const self: *Fiber = @alignCast(@ptrCast(ctx));
            const old_ctx = current_fiber;
            current_fiber = self;
            self.coroutine.@"resume"();
            if (self.coroutine.is_completed) {
                if (owns_stack) {
                    self.coroutine.deinit();
                }
            } else {
                self.scheduleSelf();
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
}
