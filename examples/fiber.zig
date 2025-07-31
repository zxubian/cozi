const std = @import("std");
const cozi = @import("cozi");
const ThreadPool = cozi.executors.threadPools.Compute;
const Fiber = cozi.Fiber;
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.detectLeaks()) {
            unreachable;
        }
    }

    // Create fixed number of "worker threads" at init time.
    var tp: ThreadPool = undefined;
    try tp.init(2, allocator);
    const executor = tp.executor();
    defer tp.deinit();
    tp.start();
    defer tp.stop();

    const Ctx = struct {
        sum: usize,
        wait_group: std.Thread.WaitGroup = .{},
        mutex: Fiber.Mutex = .{},
        pub fn run(
            self: *@This(),
        ) void {
            for (0..10) |_| {
                {
                    // Fibers running on thread pool may access
                    // shared variable `sum` in parallel.
                    // Fiber.Mutex provides mutual exclusion without
                    // blocking underlying thread.
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.sum += 1;
                }
                // Suspend execution here (allowing for other fibers to be run),
                // and immediately reschedule self with the Executor.
                Fiber.yield();
            }
            self.wait_group.finish();
        }
    };
    var ctx: Ctx = .{ .sum = 0 };
    const fiber_count = 4;
    ctx.wait_group.startMany(fiber_count);

    // Run 4 fibers on 2 threads
    for (0..fiber_count) |fiber_id| {
        try Fiber.goWithNameFmt(
            Ctx.run,
            .{&ctx},
            allocator,
            executor,
            "Fiber #{}",
            .{fiber_id},
        );
    }
    // Synchronize Fibers running in a thread pool
    // with the launching (main) thread.
    ctx.wait_group.wait();
}
