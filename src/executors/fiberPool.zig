const std = @import("std");

const cozi = @import("../root.zig");
const executors = cozi.executors;
const Executor = executors.Executor;
const Fiber = cozi.Fiber;
const core = cozi.core;
const Runnable = core.Runnable;
const Stack = core.Stack;

const TaskQueue = @import("./fiberPool/queue.zig");

const FiberPool = @This();
fibers: []*Fiber,
task_queue: TaskQueue = .{},
allocator: std.mem.Allocator,
join_wait_group: std.Thread.WaitGroup = .{},

pub const Options = struct {
    fiber_count: usize,
    stack_size: usize = Stack.default_size_bytes,
    pool_name: [:0]const u8 = "Fiber pool",
};

pub fn init(
    allocator: std.mem.Allocator,
    inner_executor: cozi.executors.Executor,
    options: Options,
) !FiberPool {
    var fiber_name_buffer: [Fiber.max_name_length_bytes:0]u8 = undefined;
    const fibers = try allocator.alloc(*Fiber, options.fiber_count);
    for (fibers, 0..) |*fiber, fiber_idx| {
        const fiber_name = try std.fmt.bufPrintZ(
            &fiber_name_buffer,
            "[{s}] fiber #{}",
            .{
                options.pool_name,
                fiber_idx,
            },
        );
        fiber.* = try Fiber.initOptions(
            fiberEntryPoint,
            .{undefined},
            allocator,
            inner_executor,
            .{
                .stack_size = options.stack_size,
                .fiber = .{
                    .name = fiber_name,
                },
            },
        );
    }
    return FiberPool{
        .fibers = fibers,
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    self.allocator.free(self.fibers);
    self.* = undefined;
}

pub fn start(self: *@This()) void {
    self.join_wait_group.startMany(self.fibers.len);
    for (self.fibers) |fiber| {
        const closure: *cozi.core.Closure(fiberEntryPoint) = @alignCast(@ptrCast(fiber.coroutine.runnable.ptr));
        closure.arguments = .{self};
        fiber.scheduleSelf();
    }
}

pub fn stop(self: *@This()) void {
    self.task_queue.tryClose() catch unreachable;
    self.join_wait_group.wait();
}

fn fiberEntryPoint(pool: *FiberPool) !void {
    while (pool.task_queue.popFront()) |next| {
        next.run();
    }
    pool.join_wait_group.finish();
}

pub fn executor(self: *FiberPool) Executor {
    return Executor{
        .ptr = self,
        .vtable = .{
            .submit = @ptrCast(&submit),
        },
    };
}

pub fn submit(
    self: *FiberPool,
    runnable: *Runnable,
) void {
    self.task_queue.pushBack(runnable);
}

test {
    _ = @import("./fiberPool/tests.zig");
}
