const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const testing = std.testing;
const fault = @import("../../../fault/main.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const Fiber = @import("../../main.zig");
const WaitGroup = Fiber.WaitGroup;

const executors = @import("../../../executors/main.zig");
const ManualExecutor = executors.Manual;
const ThreadPool = executors.threadPools.Compute;
const ThreadWaitGroup = std.Thread.WaitGroup;

test "counter - single thread" {
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var manual_executor = ManualExecutor{};
    const count: usize = 100;
    const Ctx = struct {
        wg: WaitGroup,
        counter: usize,

        pub fn runProducer(self: *@This()) void {
            self.counter += 1;
            self.wg.done();
        }
        pub fn runConsumer(self: *@This()) !void {
            self.wg.wait();
            try testing.expectEqual(count, self.counter);
        }
    };
    var ctx: Ctx = .{
        .wg = .{},
        .counter = 0,
    };
    ctx.wg.add(count);
    try Fiber.goOptions(
        Ctx.runConsumer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
        .{ .stack_size = 1024 * 16 },
    );
    for (0..count) |_| {
        try Fiber.goOptions(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            manual_executor.executor(),
            .{ .stack_size = 1024 * 16 },
        );
    }
    _ = manual_executor.drain();
    try testing.expectEqual(count, ctx.counter);
}

test "counter - multi-thread" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const count: usize = 500;
    const Ctx = struct {
        wg: WaitGroup = .{},
        counter: Atomic(usize) = .init(0),
        thread_wg: ThreadWaitGroup = .{},

        pub fn runProducer(self: *@This()) void {
            _ = self.counter.fetchAdd(1, .seq_cst);
            self.wg.done();
            self.thread_wg.finish();
        }
        pub fn runConsumer(self: *@This()) !void {
            self.wg.wait();
            try testing.expectEqual(count, self.counter.load(.seq_cst));
            self.thread_wg.finish();
        }
    };
    var ctx: Ctx = .{};
    ctx.wg.add(count);
    ctx.thread_wg.startMany(count + 1);
    try Fiber.goOptions(
        Ctx.runConsumer,
        .{&ctx},
        testing.allocator,
        tp.executor(),
        .{ .stack_size = 1024 * 16 },
    );
    for (0..count) |_| {
        try Fiber.goOptions(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
            .{ .stack_size = 1024 * 16 },
        );
    }
    ctx.thread_wg.wait();
    try testing.expectEqual(count, ctx.counter.load(.seq_cst));
}

test "stress" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const fibers: usize = 1000;
    const iterations_per_fiber: usize = 1000;
    const count = fibers * iterations_per_fiber;

    const Ctx = struct {
        wg: WaitGroup = .{},
        producer_ready: WaitGroup = .{},
        counter: Atomic(usize) = .init(0),
        join_done: bool = false,
        thread_wg: ThreadWaitGroup = .{},

        pub fn runProducer(self: *@This()) void {
            for (0..iterations_per_fiber) |_| {
                self.wg.add(1);
                Fiber.yield();
            }
            self.producer_ready.done();
            self.thread_wg.finish();
        }

        pub fn runConsumer(self: *@This()) !void {
            self.producer_ready.wait();
            for (0..iterations_per_fiber) |_| {
                _ = self.counter.fetchAdd(1, .seq_cst);
                self.wg.done();
                Fiber.yield();
            }
            self.thread_wg.finish();
        }

        pub fn join(self: *@This()) !void {
            self.wg.wait();
            try testing.expectEqual(
                count,
                self.counter.load(.seq_cst),
            );
            self.join_done = true;
            self.thread_wg.finish();
        }
    };
    var ctx: Ctx = .{};
    for (0..fibers) |_| {
        ctx.producer_ready.add(1);
        ctx.thread_wg.start();
        try Fiber.goOptions(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
            .{ .stack_size = 1024 * 16 },
        );
        ctx.thread_wg.start();
        try Fiber.goOptions(
            Ctx.runConsumer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
            .{ .stack_size = 1024 * 16 },
        );
    }
    ctx.thread_wg.start();
    try Fiber.goOptions(
        Ctx.join,
        .{&ctx},
        testing.allocator,
        tp.executor(),
        .{ .stack_size = 1024 * 16 },
    );
    ctx.thread_wg.wait();
    try testing.expectEqual(count, ctx.counter.load(.seq_cst));
    try testing.expectEqual(true, ctx.join_done);
}
