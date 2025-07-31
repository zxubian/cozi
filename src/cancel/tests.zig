const std = @import("std");

const cozi = @import("../root.zig");
const testing = std.testing;
const futures = cozi.future.lazy;
const log = cozi.core.log.scoped(._test);
const await = cozi.await.await;
const CancelContext = cozi.cancel.Context;
const Fiber = cozi.Fiber;

test "cancel - fiber pool" {
    var tp = try cozi.executors.threadPools.Compute.init(
        1,
        testing.allocator,
    );
    defer tp.deinit();
    try tp.start();
    defer tp.stop();
    var fiber_pool = try cozi.executors.FiberPool.init(
        testing.allocator,
        tp.executor(),
        .{
            .fiber_count = 1,
        },
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
    std.Thread.sleep(std.time.ns_per_ms * 300);
    fiber_pool.cancel_context.cancel();
}
