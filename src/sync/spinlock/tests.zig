const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const WaitGroup = std.Thread.WaitGroup;
const Executors = @import("../../executors/main.zig");
const ThreadPool = Executors.ThreadPools.Compute;

const Spinlock = @import("../spinlock.zig");

test "basic" {
    var lock: Spinlock = .{};
    var a: u8 = 0;
    {
        var guard = lock.guard();
        guard.lock();
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
    var wait_group: WaitGroup = .{};

    const Ctx = struct {
        counter: usize = 0,
        lock: *Spinlock,
        wait_group: *WaitGroup,

        pub fn run(self: *@This()) !void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            self.counter += 1;
            self.wait_group.finish();
        }
    };
    var ctx: Ctx = .{
        .lock = &lock,
        .counter = 0,
        .wait_group = &wait_group,
    };
    const count = 100500;
    wait_group.startMany(count);
    for (0..count) |_| {
        tp.executor().submit(Ctx.run, .{&ctx}, testing.allocator);
    }
    try tp.start();
    defer tp.stop();

    wait_group.wait();
    try testing.expect(ctx.counter == count);
}
