const std = @import("std");
const time = std.time;
const testing = std.testing;
const gpa = testing.allocator;

const ThreadPool = @import("../../executors.zig").ThreadPools.Compute;
const IoDispatch = @import("../dispatch.zig");

test "IO Dispatch" {
    var thread_pool = try ThreadPool.init(1, gpa);
    defer thread_pool.deinit();
    try thread_pool.start();
    defer thread_pool.stop();

    var dispatch = try IoDispatch.init(
        .{ .callback_entry_allocator = gpa },
        thread_pool.executor(),
        gpa,
    );
    defer dispatch.deinit();

    const Ctx = struct {
        step: usize = 0,
        pub fn run(self_: ?*anyopaque) void {
            var self = @as(*@This(), @alignCast(@ptrCast(self_)));
            self.step += 1;
        }
    };

    var ctx = Ctx{};

    try dispatch.timer(
        time.ns_per_s * 3,
        Ctx.run,
        &ctx,
    );
    thread_pool.waitIdle();

    try testing.expectEqual(1, ctx.step);
}
