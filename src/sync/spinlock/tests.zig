const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const Thread = std.Thread;
const WaitGroup = Thread.WaitGroup;
const executors = @import("../../executors/root.zig");
const ThreadPool = executors.threadPools.Compute;

const Spinlock = @import("../spinlock.zig");

test "Spinlock - basic" {
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

test "SpinLock - counter" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var lock: Spinlock = .{};
    const thread_count = try std.Thread.getCpuCount();
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

test "Spinlock - deadlock" {
    return error.SkipZigTest;
    // const thread_count = 3;
    // var tp: ThreadPool = try .init(thread_count, testing.allocator);
    // defer tp.deinit();

    // // A -> B -> C -> A

    // const Ctx = struct {
    //     lock_a: Spinlock = .{},
    //     lock_b: Spinlock = .{},
    //     lock_c: Spinlock = .{},

    //     barrier: std.atomic.Value(usize) = .init(3),

    //     pub fn A(ctx: *@This()) !void {
    //         var a = ctx.lock_a.guard();
    //         a.lock();
    //         _ = ctx.barrier.fetchSub(1, .seq_cst);
    //         while (ctx.barrier.load(.seq_cst) > 0) {
    //             std.atomic.spinLoopHint();
    //         }
    //         var b = ctx.lock_c.guard();
    //         b.lock();
    //         while (true) {}
    //     }

    //     pub fn B(ctx: *@This()) !void {
    //         var b = ctx.lock_b.guard();
    //         b.lock();
    //         _ = ctx.barrier.fetchSub(1, .seq_cst);
    //         while (ctx.barrier.load(.seq_cst) > 0) {
    //             std.atomic.spinLoopHint();
    //         }
    //         var c = ctx.lock_c.guard();
    //         c.lock();
    //         while (true) {}
    //     }

    //     pub fn C(ctx: *@This()) !void {
    //         var c = ctx.lock_c.guard();
    //         c.lock();
    //         _ = ctx.barrier.fetchSub(1, .seq_cst);
    //         while (ctx.barrier.load(.seq_cst) > 0) {
    //             std.atomic.spinLoopHint();
    //         }
    //         var a = ctx.lock_a.guard();
    //         a.lock();
    //         while (true) {}
    //     }
    // };
    // var ctx: Ctx = .{};
    // const executor = tp.executor();
    // executor.submit(Ctx.A, .{&ctx}, testing.allocator);
    // executor.submit(Ctx.B, .{&ctx}, testing.allocator);
    // executor.submit(Ctx.C, .{&ctx}, testing.allocator);
    // try tp.start();
    // defer tp.stop();
    // while (true) {}
}
