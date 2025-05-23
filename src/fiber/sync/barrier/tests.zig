const std = @import("std");
const builtin = @import("builtin");

const cozi = @import("../../../root.zig");
const build_options = cozi.build_options.options;
const testing = std.testing;
const fault = cozi.fault;
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const Allocator = std.mem.Allocator;
const WaitGroup = std.Thread.WaitGroup;

const Fiber = cozi.Fiber;
const Barrier = Fiber.Barrier;
const Mutex = Fiber.Mutex;
const executors = cozi.executors;
const ManualExecutor = executors.Manual;
const ThreadPool = executors.threadPools.Compute;
const Executor = executors.Executor;

test "barrier - basic - single thread" {
    var executor = ManualExecutor{};
    const fiber_count = 5;
    const Ctx = struct {
        state: [fiber_count]usize = undefined,
        barrier: Barrier = .{},
        mutex: Mutex = .{},

        pub fn run(ctx: *@This(), i: usize) !void {
            ctx.state[i] += 1;
            ctx.barrier.join();
            {
                ctx.mutex.lock();
                defer ctx.mutex.unlock();
                var j: usize = 0;
                for (ctx.state) |s| {
                    try testing.expect(s > 0);
                    j += 1;
                }
            }
            ctx.state[i] += 1;
        }
    };
    var ctx: Ctx = .{
        .state = std.mem.zeroes([fiber_count]usize),
    };
    ctx.barrier.add(fiber_count);
    for (0..fiber_count) |i| {
        try Fiber.go(
            Ctx.run,
            .{ &ctx, i },
            testing.allocator,
            executor.executor(),
        );
    }
    _ = executor.drain();
    for (ctx.state) |s| {
        try testing.expectEqual(2, s);
    }
}

test "barrier - stress" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const runs = 10;
    for (0..runs) |_| {
        const cpu_count = try std.Thread.getCpuCount();
        _ = cpu_count;
        var tp = try ThreadPool.init(
            2,
            testing.allocator,
        );
        defer tp.deinit();
        try tp.start();
        defer tp.stop();

        const fiber_count = 10;
        const stages = 1;

        const Ctx = struct {
            state: []Atomic(usize),
            barrier: Barrier = .{},
            mutex: Mutex = .{},
            allocator: Allocator,
            executor: Executor,
            done: bool,
            wait_group: WaitGroup = .{},

            pub fn leader(ctx: *@This()) !void {
                for (0..stages) |stage| {
                    ctx.barrier = .{};
                    ctx.barrier.add(fiber_count + 1);
                    for (0..fiber_count) |i| {
                        try Fiber.goOptions(
                            @This().run,
                            .{ ctx, i, stage },
                            ctx.allocator,
                            ctx.executor,
                            .{ .stack_size = 1024 * 16 },
                        );
                    }
                    ctx.barrier.join();
                    {
                        ctx.mutex.lock();
                        defer ctx.mutex.unlock();
                        for (ctx.state) |s| {
                            try testing.expect(s.load(.seq_cst) >= stage);
                        }
                    }
                    Fiber.yield();
                }
                ctx.done = true;
                ctx.wait_group.finish();
            }

            pub fn run(ctx: *@This(), i: usize, stage: usize) !void {
                _ = ctx.state[i].fetchAdd(1, .seq_cst);
                ctx.barrier.join();
                {
                    ctx.mutex.lock();
                    defer ctx.mutex.unlock();
                    for (ctx.state) |s| {
                        try testing.expect(s.load(.seq_cst) >= stage);
                    }
                }
                ctx.wait_group.finish();
            }
        };

        const state = try testing.allocator.alloc(Atomic(usize), fiber_count);
        defer testing.allocator.free(state);
        for (state) |*s| {
            s.* = Atomic(usize).init(0);
        }

        var ctx: Ctx = .{
            .state = state,
            .allocator = testing.allocator,
            .executor = tp.executor(),
            .done = false,
        };
        ctx.wait_group.startMany(fiber_count * stages + 1);
        try Fiber.go(
            Ctx.leader,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
        ctx.wait_group.wait();
        try testing.expect(ctx.done);
        for (ctx.state) |s| {
            try testing.expectEqual(stages, s.load(.seq_cst));
        }
    }
}
