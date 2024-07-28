const std = @import("std");
const builtin = @import("builtin");
const ThreadPool = @import("../threadPool.zig");
const testing = std.testing;

test "Thread Pool Capture" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(1, testing.allocator);
    defer tp.deinit();

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
}

test "Wait" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(1, testing.allocator);
    defer tp.deinit();

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
    defer tp.deinit();
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
    try testing.expectEqual(task_count, ctx.tasks.load(.seq_cst));
}

test "Parallel" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    var tasks = std.atomic.Value(usize).init(0);
    const Context = struct {
        tasks: *std.atomic.Value(usize),
        sleep_nanoseconds: u64,
        pub fn Run(self: *@This()) void {
            if (self.sleep_nanoseconds > 0) {
                std.time.sleep(self.sleep_nanoseconds);
            }
            _ = self.tasks.fetchAdd(1, .seq_cst);
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
    tp.waitIdle();
    tp.stop();
    try testing.expectEqual(2, tasks.load(.seq_cst));
}

test "Two Pools" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp1 = try ThreadPool.init(1, testing.allocator);
    var tp2 = try ThreadPool.init(1, testing.allocator);
    defer tp1.deinit();
    defer tp2.deinit();
    try tp1.start();
    try tp2.start();
    var tasks = std.atomic.Value(usize).init(0);
    const Context = struct {
        tasks: *std.atomic.Value(usize),
        sleep_nanoseconds: u64,
        pub fn Run(self: *@This()) void {
            if (self.sleep_nanoseconds > 0) {
                std.time.sleep(self.sleep_nanoseconds);
            }
            _ = self.tasks.fetchAdd(1, .seq_cst);
        }
    };
    var ctx = Context{
        .tasks = &tasks,
        .sleep_nanoseconds = std.time.ns_per_s,
    };

    const start_time = try std.time.Instant.now();

    try tp1.submit(Context.Run, .{&ctx});
    try tp2.submit(Context.Run, .{&ctx});

    tp2.waitIdle();
    tp2.stop();
    tp1.waitIdle();
    tp1.stop();

    const end_time = try std.time.Instant.now();
    const elapsed_ns = std.time.Instant.since(end_time, start_time);

    try testing.expectEqual(2, tasks.load(.seq_cst));
    try testing.expect(elapsed_ns / std.time.ns_per_ms < 1500);
}

test "Stop" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(1, testing.allocator);
    defer tp.deinit();
    try tp.start();
    const Context = struct {
        pub fn Run(_: *@This()) void {
            std.time.sleep(std.time.ns_per_ms * 128);
        }
    };
    var ctx = Context{};
    for (0..3) |_| {
        try tp.submit(Context.Run, .{&ctx});
    }
    tp.stop();
    try testing.expectEqual(0, tp.tasks.backing_queue.len);
}
