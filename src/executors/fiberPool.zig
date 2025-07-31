const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../root.zig");
const executors = cozi.executors;
const Executor = executors.Executor;
const Fiber = cozi.Fiber;
const core = cozi.core;
const Runnable = core.Runnable;
const Stack = core.Stack;
const cancel = cozi.cancel;

const log = cozi.core.log.scoped(.fiber_pool);

const TaskQueue = @import("./fiberPool/queue.zig");

const FiberPool = @This();
fibers: []*Fiber,
task_queue: TaskQueue = .{},
allocator: std.mem.Allocator,
join_wait_group: std.Thread.WaitGroup = .{},
stack_arena: []align(16) u8,
cancel_context: cancel.Context = .{},

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
    assert(options.stack_size > 0);
    assert(options.fiber_count > 0);
    var fiber_name_buffer: [Fiber.max_name_length_bytes:0]u8 = undefined;
    const fibers = try allocator.alloc(*Fiber, options.fiber_count);
    const stack_padding = std.mem.alignForward(
        u64,
        options.stack_size,
        Stack.alignment_bytes,
    ) - options.stack_size;
    const stack_arena_size = options.stack_size * options.fiber_count + (stack_padding * (options.fiber_count - 1));
    const stack_arena = try allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(Stack.alignment_bytes),
        stack_arena_size,
    );
    for (fibers, 0..) |*fiber, fiber_idx| {
        const fiber_name = try std.fmt.bufPrintZ(
            &fiber_name_buffer,
            "[{s}] fiber #{}",
            .{
                options.pool_name,
                fiber_idx,
            },
        );
        const stack_begin_offset = std.mem.alignForward(
            u64,
            fiber_idx * options.stack_size,
            Stack.alignment_bytes,
        );
        const stack: Stack = .{
            .slice = @alignCast(
                stack_arena[stack_begin_offset .. stack_begin_offset + options.stack_size],
            ),
        };
        fiber.* = try Fiber.initWithStack(
            fiberEntryPoint,
            .{
                undefined,
            },
            stack,
            inner_executor,
            .{
                .name = fiber_name,
            },
        );
    }
    return FiberPool{
        .fibers = fibers,
        .allocator = allocator,
        .stack_arena = stack_arena,
        .cancel_context = .{},
    };
}

pub fn deinit(self: *@This()) void {
    assert(self.task_queue.closed());
    assert(self.task_queue.idle_fibers.isEmpty());
    for (self.fibers) |f| {
        assert(f.state.load(.seq_cst) == .finished);
    }
    self.allocator.free(self.stack_arena);
    self.allocator.free(self.fibers);
    self.* = undefined;
}

pub fn start(self: *@This()) void {
    self.join_wait_group.startMany(self.fibers.len);
    for (self.fibers) |fiber| {
        const closure: *cozi.core.Closure(fiberEntryPoint) =
            @alignCast(
                @ptrCast(fiber.coroutine.runnable.ptr),
            );
        closure.arguments = .{
            self,
        };
        self.cancel_context.link(&fiber.cancel_context) catch unreachable;
        fiber.pool = self;
        fiber.scheduleSelf();
    }
}

pub fn stop(self: *@This()) void {
    log.debug("stopping fiber pool", .{});
    self.task_queue.tryClose() catch unreachable;
    self.join_wait_group.wait();
    while (true) {
        const all_fibers_finished = for (self.fibers) |fiber| {
            if (fiber.state.load(.seq_cst) == .finished) {
                continue;
            }
            break false;
        } else true;
        if (all_fibers_finished) {
            break;
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

fn fiberEntryPoint(pool: *FiberPool) !void {
    const self = Fiber.current();
    log.debug("{s}: started", .{self.?.name});
    while (pool.task_queue.popFront()) |next| {
        log.debug("{s}: acquired new task {*}", .{
            self.?.name,
            next,
        });
        next.run();
    }
    log.debug("{s}: task queue closed -> finishing", .{self.?.name});
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
    self.task_queue.pushBack(runnable) catch {};
}

test {
    _ = @import("./fiberPool/tests.zig");
}
