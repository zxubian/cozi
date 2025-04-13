const std = @import("std");
const Zinc = @import("zinc");
const ThreadPool = Zinc.executors.threadPools.Compute;

pub fn main() !void {
    const Ctx = struct {
        wait_group: std.Thread.WaitGroup = .{},

        pub fn run(self: *@This()) void {
            self.wait_group.finish();
        }
    };

    const task_count = 4;
    var ctx: Ctx = .{};
    ctx.wait_group.startMany(task_count);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    defer {
        if (gpa.detectLeaks()) {
            unreachable;
        }
    }

    var tp = try ThreadPool.init(4, allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    for (0..task_count) |_| {
        tp.executor().submit(Ctx.run, .{&ctx}, allocator);
    }
    ctx.wait_group.wait();
}
