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

test "Wait" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(1, testing.allocator);
    try tp.start();

    const Context = struct {
        done: bool,
        pub fn run(self: *@This()) void {
            std.time.sleep(std.time.ns_per_ms);
            self.done = true;
        }
    };
    var ctx = Context{ .done = false };
    try tp.submit(Context.run, .{&ctx});

    tp.waitIdle();
    tp.stop();
    tp.deinit();

    try testing.expect(ctx.done);
}

test "MultiWait" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(1, testing.allocator);
    try tp.start();

    const Context = struct {
        done: bool,
        pub fn run(self: *@This()) void {
            std.time.sleep(std.time.ns_per_ms);
            self.done = true;
        }
    };
    for (0..3) |_| {
        var ctx = Context{ .done = false };
        try tp.submit(Context.run, .{&ctx});
        tp.waitIdle();
        try testing.expect(ctx.done);
    }
    tp.stop();
    tp.deinit();
}

test "Many Tasks" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    try tp.start();

    const task_count: usize = 17;

    const Context = struct {
        tasks: std.atomic.Value(usize),

        pub fn run(self: *@This()) void {
            _ = self.tasks.fetchAdd(1, .acq_rel);
        }
    };
    var ctx = Context{ .tasks = std.atomic.Value(usize).init(0) };
    for (0..task_count) |_| {
        try tp.submit(Context.run, .{&ctx});
    }
    tp.waitIdle();
    tp.stop();
    tp.deinit();
    try testing.expectEqual(task_count, ctx.tasks.load(.seq_cst));
}

test "Parallel" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    try tp.start();
    var tasks = std.atomic.Value(usize).init(0);
    const Context = struct {
        tasks: *std.atomic.Value(usize),
        sleep_nanoseconds: u64,
        pub fn Run(self: *@This()) void {
            std.debug.print("running!\n", .{});
            if (self.sleep_nanoseconds > 0) {
                std.debug.print("gonna sleep for {}ns!\n", .{self.sleep_nanoseconds});
                std.time.sleep(self.sleep_nanoseconds);
            }
            std.debug.print("about to add !\n", .{});
            const res = self.tasks.fetchAdd(1, .seq_cst);
            std.debug.print("fetch add result {}!\n", .{res + 1});
        }
    };
    var ctx_a = Context{
        .tasks = &tasks,
        .sleep_nanoseconds = std.time.ns_per_s,
    };
    try tp.submit(Context.Run, .{&ctx_a});
    var ctx_b = Context{
        .tasks = &tasks,
        .sleep_nanoseconds = 0,
    };
    try tp.submit(Context.Run, .{&ctx_b});
    std.time.sleep(std.time.ns_per_ms * 500);
    try testing.expectEqual(1, tasks.load(.seq_cst));
    std.debug.print("about to wait Idle\n", .{});
    tp.waitIdle();
    std.debug.print("wait Idle returned\n", .{});
    tp.stop();
    tp.deinit();
    try testing.expectEqual(2, tasks.load(.seq_cst));
}
