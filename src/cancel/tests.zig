const std = @import("std");

const cozi = @import("../root.zig");
const testing = std.testing;
const futures = cozi.future.lazy;
const log = cozi.core.log.scoped(._test);
const await = cozi.await.await;
const CancelContext = cozi.cancel.Context;
const Fiber = cozi.Fiber;

// test "cancel - fiber pool" {
// var fiber_pool: cozi.executors.FiberPool.Default = undefined;
// try fiber_pool.init(testing.allocator);
// fiber_pool.start();
// defer fiber_pool.stop();

// const Ctx = struct {
//     pub fn a() void {
//         while (true) {
//             log.debug("yield", .{});
//             cozi.Fiber.yield();
//         }
//     }
// };
// fiber_pool.executor().submit(Ctx.a, .{}, testing.allocator);
// std.Thread.sleep(std.time.ns_per_ms * 300);
// fiber_pool.fiber_pool.cancel_context.cancel();
// }

