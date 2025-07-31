const std = @import("std");
const builtin = @import("builtin");

const cozi = @import("../root.zig");
const testing = std.testing;
const futures = cozi.future.lazy;
const log = cozi.core.log.scoped(._test);
const await = cozi.await.await;
const CancelContext = cozi.cancel.Context;
const Fiber = cozi.Fiber;
const ThreadPool = cozi.executors.threadPools.Compute;

const CancelFiberPoolTestCaseOptions = struct {
    thread_count: usize,
    fiber_count: usize,
    delay_before_cancel_ns: usize,
};

fn testCancelFiberPool(options: CancelFiberPoolTestCaseOptions) !void {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp: ThreadPool = undefined;
    try tp.init(
        options.thread_count,
        testing.allocator,
    );
    defer tp.deinit();
    tp.start();
    defer tp.stop();

    var fiber_pool: cozi.executors.FiberPool = undefined;
    try fiber_pool.init(
        testing.allocator,
        tp.executor(),
        .{ .fiber_count = options.fiber_count },
    );
    defer fiber_pool.deinit();
    fiber_pool.start();
    defer fiber_pool.stop();

    const Ctx = struct {
        pub fn a() void {
            while (true) {
                log.debug("yield", .{});
                cozi.Fiber.yield();
            }
        }
    };
    fiber_pool.executor().submit(Ctx.a, .{}, testing.allocator);
    std.Thread.sleep(options.delay_before_cancel_ns);
    fiber_pool.cancel_context.cancel();
}

test "cancel - fiber pool - 1:1" {
    try testCancelFiberPool(.{
        .thread_count = 1,
        .fiber_count = 1,
        .delay_before_cancel_ns = 300 * std.time.ns_per_ms,
    });
}

test "cancel - fiber pool - 1:2" {
    try testCancelFiberPool(.{
        .thread_count = 1,
        .fiber_count = 2,
        .delay_before_cancel_ns = 300 * std.time.ns_per_ms,
    });
}

test "cancel - fiber pool - 1:M" {
    const cpu_count = try std.Thread.getCpuCount();
    try testCancelFiberPool(.{
        .thread_count = 1,
        .fiber_count = cpu_count * 2,
        .delay_before_cancel_ns = 300 * std.time.ns_per_ms,
    });
}

test "cancel - fiber pool - 2:1" {
    try testCancelFiberPool(.{
        .thread_count = 2,
        .fiber_count = 1,
        .delay_before_cancel_ns = 300 * std.time.ns_per_ms,
    });
}

test "cancel - fiber pool - 2:2" {
    try testCancelFiberPool(.{
        .thread_count = 2,
        .fiber_count = 2,
        .delay_before_cancel_ns = 300 * std.time.ns_per_ms,
    });
}

test "cancel - fiber pool - M:M" {
    const cpu_count = try std.Thread.getCpuCount();
    try testCancelFiberPool(.{
        .thread_count = cpu_count,
        .fiber_count = cpu_count * 2,
        .delay_before_cancel_ns = 300 * std.time.ns_per_ms,
    });
}
//         }
//     }
// };
// fiber_pool.executor().submit(Ctx.a, .{}, testing.allocator);
// std.Thread.sleep(std.time.ns_per_ms * 300);
// fiber_pool.fiber_pool.cancel_context.cancel();
// }

