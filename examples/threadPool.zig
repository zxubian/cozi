const std = @import("std");
const zinc = @import("zinc");
const ThreadPool = zinc.executors.threadPools.Compute;
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
    var thread_pool = try ThreadPool.init(4, allocator);
    defer thread_pool.deinit();
    try thread_pool.start();
    defer thread_pool.stop();

    const Ctx = struct {
        wait_group: std.Thread.WaitGroup = .{},
        sum: std.atomic.Value(usize) = .init(0),

        pub fn run(self: *@This()) void {
            _ = self.sum.fetchAdd(1, .seq_cst);
            self.wait_group.finish();
        }
    };

    var ctx: Ctx = .{};
    const task_count = 4;
    ctx.wait_group.startMany(task_count);
    for (0..task_count) |_| {
        // submit tasks to worker threads
        thread_pool.executor().submit(Ctx.run, .{&ctx}, allocator);
    }
    // Submitted task will eventually be executed by some worker thread.
    // To wait for task completion, need to either synchronize manually
    // by using WaitGroup etc. as below, or use higher-level primitives
    // like Futures.
    ctx.wait_group.wait();
    assert(ctx.sum.load(.seq_cst) == task_count);
}
