const std = @import("std");
const builtin = @import("builtin");
const ThreadPool = @import("../threadPool.zig");
const testing = std.testing;

test "Thread Pool Capture" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(1, testing.allocator);
    const Context = struct {
        a: usize,
        pub fn run(self: *@This()) void {
            self.a += 1;
        }
    };
    var ctx = Context{ .a = 0 };
    try tp.submit(Context.run, .{&ctx});
    try testing.expectEqual(0, ctx.a);
    try tp.start();
    std.time.sleep(std.time.ns_per_ms);
    try testing.expectEqual(1, ctx.a);

    try tp.submit(Context.run, .{&ctx});
    std.time.sleep(std.time.ns_per_ms);
    try testing.expectEqual(2, ctx.a);

    try tp.submit(Context.run, .{&ctx});
    try tp.submit(Context.run, .{&ctx});
    tp.waitIdle();
    try testing.expectEqual(4, ctx.a);

    tp.stop();
    tp.deinit();
}
