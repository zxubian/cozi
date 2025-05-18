const std = @import("std");
const testing = std.testing;

const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;
const executors = cozi.executors;
const ManualExecutor = executors.Manual;
const FiberPool = executors.FiberPool;
const ThreadPool = executors.threadPools.Compute;

test "Fiber Pool - basic" {
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
