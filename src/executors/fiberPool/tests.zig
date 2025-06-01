const std = @import("std");
const testing = std.testing;

const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;
const executors = cozi.executors;
const ManualExecutor = executors.Manual;
const FiberPool = executors.FiberPool;
const ThreadPool = executors.threadPools.Compute;

const future = cozi.future.lazy;

test "Fiber Pool - basic" {
    if (cozi.build_options.options.sanitizer_variant == .thread) {
        return error.SkipZigTest;
    }
    var thread_pool = try ThreadPool.init(1, testing.allocator);
    defer thread_pool.deinit();
    try thread_pool.start();
    defer thread_pool.stop();
    var fiber_pool = try FiberPool.init(
        testing.allocator,
        thread_pool.executor(),
        .{
            .fiber_count = 4,
        },
    );
    defer fiber_pool.deinit();
    fiber_pool.start();
    defer fiber_pool.stop();
}

test "Fiber Pool - future" {
    if (cozi.build_options.options.sanitizer_variant == .thread) {
        return error.SkipZigTest;
    }
    var thread_pool = try ThreadPool.init(
        1,
        testing.allocator,
    );
    defer thread_pool.deinit();
    try thread_pool.start();
    defer thread_pool.stop();

    var fiber_pool = try FiberPool.init(
        testing.allocator,
        thread_pool.executor(),
        .{
            .fiber_count = 1,
        },
    );
    defer fiber_pool.deinit();
    fiber_pool.start();
    defer fiber_pool.stop();

    const executor = fiber_pool.executor();
    const Ctx = struct {
        done: bool,
        pub fn run(self: *@This()) !void {
            self.done = true;
        }
    };
    var ctx: Ctx = .{
        .done = false,
    };
    const f = future.submit(
        executor,
        Ctx.run,
        .{&ctx},
    );
    try future.get(f);
    try testing.expect(ctx.done);
}

test "Fiber Pool - future - stress " {
    if (cozi.build_options.options.sanitizer_variant == .thread) {
        return error.SkipZigTest;
    }
    var thread_pool = try ThreadPool.init(
        try std.Thread.getCpuCount(),
        testing.allocator,
    );
    defer thread_pool.deinit();
    try thread_pool.start();
    defer thread_pool.stop();

    var fiber_pool = try FiberPool.init(
        testing.allocator,
        thread_pool.executor(),
        .{
            .fiber_count = 100,
        },
    );
    defer fiber_pool.deinit();
    fiber_pool.start();
    defer fiber_pool.stop();

    const executor = fiber_pool.executor();
    const future_count = 10;
    const iterations_per_future = 1000;
    const Ctx = struct {
        stage: usize,
        mutex: Fiber.Mutex = .{},
        done: [future_count]bool = [_]bool{false} ** future_count,
        pub fn run(
            self: *@This(),
            idx: usize,
        ) !void {
            for (0..iterations_per_future) |_| {
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.stage += 1;
                }
                Fiber.yield();
            }
            self.done[idx] = true;
        }
    };
    var ctx: Ctx = .{
        .stage = 0,
    };
    var futures: std.meta.Tuple(
        &[_]type{
            future.Submit(
                @TypeOf(Ctx.run),
                std.meta.ArgsTuple(@TypeOf(Ctx.run)),
            ),
        } ** future_count,
    ) = undefined;
    inline for (&futures, 0..) |*f, i| {
        const idx: usize = i;
        f.* = future.submit(
            executor,
            Ctx.run,
            .{ &ctx, idx },
        );
    }
    const pipeline = future.pipeline(.{
        future.just(),
        future.via(thread_pool.executor()),
        future.all(futures),
    });
    _ = future.get(pipeline);
    for (ctx.done) |i| {
        try testing.expect(i);
    }
    try testing.expectEqual(
        iterations_per_future * future_count,
        ctx.stage,
    );
}
