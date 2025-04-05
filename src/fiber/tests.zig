const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const assert = std.debug.assert;
const testing = std.testing;
const alloc = testing.allocator;
const fault = @import("../fault/main.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const WaitGroup = std.Thread.WaitGroup;

const Fiber = @import("./main.zig");
const Executors = @import("../executors/main.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const Stack = @import("../core/main.zig").Stack;

test {
    _ = @import("./sync.zig");
}

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
    const Ctx = struct {
        step: usize = 0,
        wait_group: WaitGroup = .{},
        pub fn run(self: *@This()) void {
            self.step += 1;
            self.wait_group.finish();
        }
    };
    var thread_pool = try ThreadPool.init(1, alloc);
    defer thread_pool.deinit();
    var ctx: Ctx = .{};
    ctx.wait_group.start();
    try Fiber.go(Ctx.run, .{&ctx}, alloc, thread_pool.executor());
    try thread_pool.start();
    defer thread_pool.stop();
    ctx.wait_group.wait();
    try testing.expectEqual(ctx.step, 1);
}

test "Fiber Yield" {
    const Ctx = struct {
        step: usize = 0,
        pub fn run(self: *@This()) void {
            for (0..3) |_| {
                self.step += 1;
                Fiber.yield();
            }
        }
    };
    var manual_executor = ManualExecutor{};
    var ctx: Ctx = .{};
    try Fiber.go(Ctx.run, .{&ctx}, alloc, manual_executor.executor());
    _ = manual_executor.drain();
    try testing.expectEqual(ctx.step, 3);
}

test "Fiber threadpool child" {
    const Ctx = struct {
        step: Atomic(usize) = .init(0),
        wait_group: WaitGroup = .{},
        pub fn run(self: *@This()) !void {
            if (self.step.fetchAdd(1, .monotonic) == 0) {
                try Fiber.go(@This().run, .{self}, alloc, Fiber.current().?.executor);
            }
            self.wait_group.finish();
        }
    };
    var thread_pool = try ThreadPool.init(1, alloc);
    defer thread_pool.deinit();
    var ctx: Ctx = .{};
    ctx.wait_group.startMany(2);
    try Fiber.go(Ctx.run, .{&ctx}, alloc, thread_pool.executor());
    try thread_pool.start();
    defer thread_pool.stop();
    ctx.wait_group.wait();
    try testing.expectEqual(ctx.step.load(.monotonic), 2);
}

test "Ping Pong" {
    const State = enum {
        ping,
        pong,
    };
    const Ctx = struct {
        state: State = .ping,
        wait_group: WaitGroup = .{},

        pub fn runPong(self: *@This()) !void {
            for (0..3) |_| {
                try std.testing.expect(self.state == .ping);
                self.state = .pong;
                Fiber.yield();
            }
            self.wait_group.finish();
        }
        pub fn runPing(self: *@This()) !void {
            for (0..3) |_| {
                try std.testing.expect(self.state == .pong);
                self.state = .ping;
                Fiber.yield();
            }
            self.wait_group.finish();
        }
    };
    var thread_pool = try ThreadPool.init(1, alloc);
    defer thread_pool.deinit();
    var ctx: Ctx = .{};
    ctx.wait_group.startMany(2);
    try Fiber.go(Ctx.runPong, .{&ctx}, alloc, thread_pool.executor());
    try Fiber.go(Ctx.runPing, .{&ctx}, alloc, thread_pool.executor());
    try thread_pool.start();
    defer thread_pool.stop();
    ctx.wait_group.wait();
}

test "Fiber - Two Pools" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    if (build_config.sanitize == .thread) {
        // crash in tsan_rtl.h:791
        //   thr->shadow_stack_pos[0] = pc;
        // --------------------------------
        // Stack:
        // MachineContext.switchTo()
        // coroutine.resume()
        // fiber.runTick()
        return error.SkipZigTest;
    }
    var wait_group: WaitGroup = .{};
    const Ctx = struct {
        wait_group: *WaitGroup,
        pub fn run(self: *@This(), expected: *ThreadPool) !void {
            const inner_count = 128;
            self.wait_group.startMany(inner_count);
            for (0..inner_count) |_| {
                try testing.expectEqual(expected, ThreadPool.current().?);
                Fiber.yield();
                const CtxInner = struct {
                    pub fn run(expected_: *ThreadPool, wait_group_: *WaitGroup) !void {
                        try testing.expectEqual(expected_, ThreadPool.current().?);
                        wait_group_.finish();
                    }
                };
                try Fiber.go(
                    CtxInner.run,
                    .{ expected, self.wait_group },
                    testing.allocator,
                    expected.executor(),
                );
            }
            self.wait_group.finish();
        }
    };
    const outer_count = 2;
    wait_group.startMany(outer_count);
    var thread_pool_a = try ThreadPool.init(1, alloc);
    defer thread_pool_a.deinit();
    var thread_pool_b = try ThreadPool.init(1, alloc);
    defer thread_pool_b.deinit();
    try thread_pool_a.start();
    defer thread_pool_a.stop();
    try thread_pool_b.start();
    defer thread_pool_b.stop();
    var ctx: Ctx = .{
        .wait_group = &wait_group,
    };
    try Fiber.go(
        Ctx.run,
        .{ &ctx, &thread_pool_a },
        alloc,
        thread_pool_a.executor(),
    );
    try Fiber.go(
        Ctx.run,
        .{ &ctx, &thread_pool_b },
        alloc,
        thread_pool_b.executor(),
    );
    wait_group.wait();
}

test "Pre-supplied stack" {
    const size = 1024 * 1024 * 16;
    const slice = try alloc.alignedAlloc(
        u8,
        Stack.ALIGNMENT_BYTES,
        size,
    );
    defer (alloc.free(slice));
    const stack = Stack{ .slice = slice };
    var step: usize = 0;
    const Ctx = struct {
        pub fn run(step_: *usize) void {
            step_.* += 1;
        }
    };
    var manual_executor = ManualExecutor{};
    try Fiber.goWithStack(
        Ctx.run,
        .{&step},
        stack,
        manual_executor.executor(),
        .{},
    );
    _ = manual_executor.drain();
    try testing.expectEqual(step, 1);
}

test "fiber - switch" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const Ctx = struct {
        manual_executor_1: *ManualExecutor,
        manual_executor_2: *ManualExecutor,
        thread_pool: *ThreadPool,
        stage: usize,
        wait_group: WaitGroup,

        inline fn expectEqualPtrs(expected: *anyopaque, actual: anytype) void {
            const actual_as_anyopaque: *anyopaque = @alignCast(@ptrCast(actual));
            assert(expected == actual_as_anyopaque);
        }

        pub fn run(self: *@This()) void {
            self.stage += 1;
            const fiber = Fiber.current().?;
            expectEqualPtrs(fiber.executor.ptr, self.manual_executor_1);
            Fiber.switchTo(self.manual_executor_2.executor());
            self.stage += 1;
            expectEqualPtrs(fiber.executor.ptr, self.manual_executor_2);
            Fiber.switchTo(self.thread_pool.executor());
            self.stage += 1;
            expectEqualPtrs(fiber.executor.ptr, self.thread_pool);
            assert(ThreadPool.current() == self.thread_pool);
            self.wait_group.finish();
        }
    };
    var manual_executor_1 = ManualExecutor{};
    var manual_executor_2 = ManualExecutor{};
    var thread_pool = try ThreadPool.init(1, alloc);
    defer thread_pool.deinit();
    var ctx: Ctx = .{
        .stage = 0,
        .manual_executor_1 = &manual_executor_1,
        .manual_executor_2 = &manual_executor_2,
        .thread_pool = &thread_pool,
        .wait_group = .{},
    };
    try Fiber.go(Ctx.run, .{&ctx}, alloc, manual_executor_1.executor());
    try testing.expectEqual(0, ctx.stage);
    _ = manual_executor_1.drain();
    try testing.expectEqual(1, ctx.stage);
    _ = manual_executor_2.drain();
    try testing.expectEqual(2, ctx.stage);
    try thread_pool.start();
    defer thread_pool.stop();
    ctx.wait_group.start();
    ctx.wait_group.wait();
    try testing.expectEqual(3, ctx.stage);
}
