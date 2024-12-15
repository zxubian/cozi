const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;
const Atomic = std.atomic.Value;

const Fiber = @import("../../fiber.zig");
const WaitGroup = Fiber.WaitGroup;

const Executors = @import("../../executors.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;

test "counter - single thread" {
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
    try Fiber.go(
        Ctx.runConsumer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    for (0..count) |_| {
        try Fiber.go(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            manual_executor.executor(),
        );
    }
    _ = manual_executor.drain();
    try testing.expectEqual(count, ctx.counter);
}

test "counter - multi-thread" {
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const count: usize = 500;
    const Ctx = struct {
        wg: WaitGroup = .{},
        counter: Atomic(usize) = .init(0),

        pub fn runProducer(self: *@This()) void {
            _ = self.counter.fetchAdd(1, .seq_cst);
            self.wg.done();
        }
        pub fn runConsumer(self: *@This()) !void {
            self.wg.wait();
            try testing.expectEqual(count, self.counter.load(.seq_cst));
        }
    };
    var ctx: Ctx = .{};
    ctx.wg.add(count);
    try Fiber.go(
        Ctx.runConsumer,
        .{&ctx},
        testing.allocator,
        tp.executor(),
    );
    for (0..count) |_| {
        try Fiber.go(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }
    _ = tp.waitIdle();
    try testing.expectEqual(count, ctx.counter.load(.seq_cst));
}

test "concurrent add & done" {
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const count: usize = 500;
    const Ctx = struct {
        wg: WaitGroup = .{},
        counter: Atomic(usize) = .init(0),
        join_done: bool = false,

        pub fn runProducer(self: *@This()) void {
            self.wg.add(1);
        }

        pub fn runConsumer(self: *@This()) !void {
            _ = self.counter.fetchAdd(1, .seq_cst);
            self.wg.done();
        }

        pub fn join(self: *@This()) !void {
            self.wg.wait();
            try testing.expectEqual(count, self.counter.load(.seq_cst));
            self.join_done = true;
        }
    };
    var ctx: Ctx = .{};
    for (0..count) |_| {
        try Fiber.go(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
        try Fiber.go(
            Ctx.runConsumer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }
    try Fiber.go(
        Ctx.join,
        .{&ctx},
        testing.allocator,
        tp.executor(),
    );
    _ = tp.waitIdle();
    try testing.expectEqual(count, ctx.counter.load(.seq_cst));
    try testing.expectEqual(true, ctx.join_done);
}

test "stress" {
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const fibers: usize = 500;
    const iterations_per_fiber: usize = 500;
    const count = fibers * iterations_per_fiber;

    const Ctx = struct {
        wg: WaitGroup = .{},
        counter: Atomic(usize) = .init(0),
        join_done: bool = false,

        pub fn runProducer(self: *@This()) void {
            for (0..iterations_per_fiber) |_| {
                self.wg.add(1);
                Fiber.yield();
            }
        }

        pub fn runConsumer(self: *@This()) !void {
            for (0..iterations_per_fiber) |_| {
                _ = self.counter.fetchAdd(1, .seq_cst);
                self.wg.done();
            }
        }

        pub fn join(self: *@This()) !void {
            self.wg.wait();
            try testing.expectEqual(
                count,
                self.counter.load(.seq_cst),
            );
            self.join_done = true;
        }
    };
    var ctx: Ctx = .{};
    for (0..fibers) |_| {
        try Fiber.go(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
        try Fiber.go(
            Ctx.runConsumer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }
    try Fiber.go(
        Ctx.join,
        .{&ctx},
        testing.allocator,
        tp.executor(),
    );
    _ = tp.waitIdle();
    try testing.expectEqual(count, ctx.counter.load(.seq_cst));
    try testing.expectEqual(true, ctx.join_done);
}
