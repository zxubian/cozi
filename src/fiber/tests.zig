const std = @import("std");
const testing = std.testing;
const alloc = testing.allocator;
const Fiber = @import("../fiber.zig");
const ManualExecutor = @import("../executors.zig").Manual;
const ThreadPool = @import("../executors.zig").ThreadPools.Compute;
const atomic = std.atomic;
const builtin = @import("builtin");

test "Fiber basic" {
    var step: usize = 0;
    const Ctx = struct {
        pub fn run(step_: *usize) void {
            step_.* += 1;
        }
    };
    var manual_executor = ManualExecutor{};
    try Fiber.go(Ctx.run, .{&step}, alloc, manual_executor.executor());
    _ = manual_executor.drain();
    try testing.expectEqual(step, 1);
}

test "Fiber context" {
    const Ctx = struct {
        pub fn run() void {
            testing.expect(Fiber.isInFiber()) catch |e| {
                std.debug.panic("Testing assertion failed: {}", .{e});
            };
        }
    };
    try testing.expect(!Fiber.isInFiber());
    var manual_executor = ManualExecutor{};
    try Fiber.go(Ctx.run, .{}, alloc, manual_executor.executor());
    _ = manual_executor.drain();
    try testing.expect(!Fiber.isInFiber());
}

test "Fiber Thread Pool" {
    var step: usize = 0;
    const Ctx = struct {
        pub fn run(step_: *usize) void {
            step_.* += 1;
        }
    };
    var thread_pool = try ThreadPool.init(1, alloc);
    defer thread_pool.deinit();
    try Fiber.go(Ctx.run, .{&step}, alloc, thread_pool.executor());
    try thread_pool.start();
    thread_pool.waitIdle();
    thread_pool.stop();
    try testing.expectEqual(step, 1);
}

test "Fiber Yield" {
    var step: usize = 0;
    const Ctx = struct {
        pub fn run(step_: *usize) void {
            for (0..3) |_| {
                step_.* += 1;
                Fiber.yield();
            }
        }
    };
    var manual_executor = ManualExecutor{};
    try Fiber.go(Ctx.run, .{&step}, alloc, manual_executor.executor());
    _ = manual_executor.drain();
    try testing.expectEqual(step, 3);
}

test "Fiber threadpool child" {
    const AtomicUsize = std.atomic.Value(usize);
    var step = AtomicUsize.init(0);
    const Ctx = struct {
        pub fn run(step_: *AtomicUsize) !void {
            if (step_.fetchAdd(1, .monotonic) == 0) {
                try Fiber.go(@This().run, .{step_}, alloc, Fiber.current().?.executor);
            }
        }
    };
    var thread_pool = try ThreadPool.init(1, alloc);
    defer thread_pool.deinit();
    try Fiber.go(Ctx.run, .{&step}, alloc, thread_pool.executor());
    try thread_pool.start();
    thread_pool.waitIdle();
    thread_pool.stop();
    try testing.expectEqual(step.load(.monotonic), 2);
}

test "Ping Pong" {
    const State = enum {
        ping,
        pong,
    };
    var state: State = .ping;
    const CtxA = struct {
        pub fn run(state_: *State) !void {
            for (0..3) |_| {
                try std.testing.expect(state_.* == .ping);
                state_.* = .pong;
                Fiber.yield();
            }
        }
    };
    const CtxB = struct {
        pub fn run(state_: *State) !void {
            for (0..3) |_| {
                try std.testing.expect(state_.* == .pong);
                state_.* = .ping;
                Fiber.yield();
            }
        }
    };
    var thread_pool = try ThreadPool.init(1, alloc);
    defer thread_pool.deinit();
    try Fiber.go(CtxA.run, .{&state}, alloc, thread_pool.executor());
    try Fiber.go(CtxB.run, .{&state}, alloc, thread_pool.executor());
    try thread_pool.start();
    thread_pool.waitIdle();
    thread_pool.stop();
}

test "Two Pools" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const Ctx = struct {
        pub fn run(expected: *ThreadPool) !void {
            for (0..128) |_| {
                try testing.expectEqual(expected, ThreadPool.current().?);
                Fiber.yield();
                const CtxInner = struct {
                    pub fn run(expected_: *ThreadPool) !void {
                        try testing.expectEqual(expected_, ThreadPool.current().?);
                    }
                };
                try Fiber.go(
                    CtxInner.run,
                    .{expected},
                    testing.allocator,
                    expected.executor(),
                );
            }
        }
    };
    var thread_pool_a = try ThreadPool.init(1, alloc);
    defer thread_pool_a.deinit();
    var thread_pool_b = try ThreadPool.init(1, alloc);
    defer thread_pool_b.deinit();
    try thread_pool_a.start();
    try thread_pool_b.start();
    try Fiber.go(
        Ctx.run,
        .{&thread_pool_a},
        alloc,
        thread_pool_a.executor(),
    );
    try Fiber.go(
        Ctx.run,
        .{&thread_pool_b},
        alloc,
        thread_pool_b.executor(),
    );
    thread_pool_a.waitIdle();
    thread_pool_b.waitIdle();
    thread_pool_a.stop();
    thread_pool_b.stop();
}
