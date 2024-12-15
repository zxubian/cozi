const Spinlock = @import("../spinlock.zig");
const std = @import("std");
const testing = std.testing;
const ThreadPool = @import("../../executors.zig").ThreadPools.Compute;
const builtin = @import("builtin");

test "basic" {
    var lock: Spinlock = .{};
    var a: u8 = 0;
    {
        var guard = lock.lock();
        a += 1;
        defer guard.unlock();
    }
    try testing.expectEqual(a, 1);
}

test "counter" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var lock: Spinlock = .{};
    const thread_count = 4;
    var tp: ThreadPool = try .init(thread_count, testing.allocator);
    defer tp.deinit();
    const Ctx = struct {
        counter: usize = 0,
        lock: *Spinlock,

        pub fn run(self: *@This()) !void {
            var guard = self.lock.lock();
            defer guard.unlock();
            self.counter += 1;
        }
    };
    var ctx: Ctx = .{
        .lock = &lock,
        .counter = 0,
    };
    const count = 100500;
    for (0..count) |_| {
        tp.executor().submit(Ctx.run, .{&ctx}, testing.allocator);
    }
    try tp.start();
    defer tp.stop();
    tp.waitIdle();
    try testing.expect(ctx.counter == count);
}
