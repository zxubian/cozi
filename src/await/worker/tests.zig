const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;
const Worker = cozi.@"await".Worker;
const Awaiter = cozi.@"await".Awaiter;
const Thread = Worker.Thread;
const ThreadPool = cozi.executors.threadPools.Compute;

test "Worker - Spawn System Thread - Current" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const Ctx = struct {
        ready: std.Thread.ResetEvent = .{},
        thread: *std.Thread = undefined,
        fn run(
            self: *@This(),
        ) !void {
            self.ready.wait();
            const this_worker = Thread.worker(self.thread);
            const previous = Worker.beginScope(this_worker);
            defer Worker.endScope(previous);
            try runInWorkerScope(self);
        }

        fn runInWorkerScope(self: *@This()) !void {
            const current_worker = Worker.current();
            try std.testing.expectEqual(.thread, current_worker.type);
            try std.testing.expectEqual(
                self.thread,
                @as(
                    *std.Thread,
                    @alignCast(
                        @ptrCast(
                            current_worker.ptr,
                        ),
                    ),
                ),
            );
        }
    };
    var ctx: Ctx = .{};
    var thread = try std.Thread.spawn(
        .{},
        Ctx.run,
        .{
            &ctx,
        },
    );
    ctx.thread = &thread;
    ctx.ready.set();
    thread.join();
}

test "Worker - Thread Pool Current" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const Ctx = struct {
        wg: std.Thread.WaitGroup = .{},
        fn run(
            self: *@This(),
        ) !void {
            const current_worker = Worker.current();
            try std.testing.expectEqual(.thread, current_worker.type);
            const found = for (ThreadPool.current().?.threads) |*thread| {
                if (thread == @as(*std.Thread, @alignCast(@ptrCast(current_worker.ptr)))) {
                    break true;
                }
            } else false;
            try testing.expect(found);
            self.wg.finish();
        }
    };
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    var ctx: Ctx = .{};
    ctx.wg.start();
    tp.executor().submit(
        Ctx.run,
        .{&ctx},
        testing.allocator,
    );
    ctx.wg.wait();
}

test "Worker - Fiber Current" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const Ctx = struct {
        wg: std.Thread.WaitGroup = .{},
        fn run(
            self: *@This(),
        ) !void {
            const current_worker = Worker.current();
            try std.testing.expectEqual(.fiber, current_worker.type);
            self.wg.finish();
        }
    };
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    var ctx: Ctx = .{};
    ctx.wg.start();

    try Fiber.go(Ctx.run, .{&ctx}, testing.allocator, tp.executor());
    ctx.wg.wait();
}
