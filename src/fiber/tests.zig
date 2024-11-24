const std = @import("std");
const testing = std.testing;
const alloc = testing.allocator;
const Fiber = @import("../fiber.zig");
const ManualExecutor = @import("../executors.zig").Manual;

test "Fiber basic" {
    var step: usize = 0;
    const Ctx = struct {
        pub fn run(step_: *usize) void {
            step_.* += 1;
        }
    };
    var manual_executor = ManualExecutor.init(alloc);
    _ = try Fiber.go(Ctx.run, .{&step}, alloc, &manual_executor.executor);
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
    var manual_executor = ManualExecutor.init(alloc);
    _ = try Fiber.go(Ctx.run, .{}, alloc, &manual_executor.executor);
    _ = manual_executor.drain();
    try testing.expect(!Fiber.isInFiber());
}
