const std = @import("std");
const builtin = @import("builtin");
const ThreadPool = @import("../compute.zig");
const testing = std.testing;
const TimeLimit = @import("../../../testing/TimeLimit.zig");
const Allocator = std.mem.Allocator;

test "Submit Lambda" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(1, alloc);
    defer tp.deinit();

    const Context = struct {
        a: usize,
        pub fn run(self: *@This()) void {
            self.a += 1;
        }
    };
    var ctx = Context{ .a = 0 };
    const executor = tp.executor();
    executor.submit(Context.run, .{&ctx}, alloc);
    try testing.expectEqual(0, ctx.a);
    try tp.start();
    std.time.sleep(std.time.ns_per_ms);
    try testing.expectEqual(1, ctx.a);

    executor.submit(Context.run, .{&ctx}, alloc);
    std.time.sleep(std.time.ns_per_ms);
    try testing.expectEqual(2, ctx.a);

    executor.submit(Context.run, .{&ctx}, alloc);
    executor.submit(Context.run, .{&ctx}, alloc);
    tp.waitIdle();
    try testing.expectEqual(4, ctx.a);

    tp.stop();
}

test "Wait" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(1, alloc);
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
    const executor = tp.executor();
    executor.submit(Context.run, .{&ctx}, alloc);

    tp.waitIdle();
    tp.stop();

    try testing.expect(ctx.done);
}

test "Multi-wait" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(1, alloc);
    try tp.start();

    const Context = struct {
        done: bool,
        pub fn run(self: *@This()) void {
            std.time.sleep(std.time.ns_per_ms);
            self.done = true;
        }
    };

    const executor = tp.executor();
    for (0..3) |_| {
        var ctx = Context{ .done = false };
        executor.submit(Context.run, .{&ctx}, alloc);
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

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(4, alloc);
    defer tp.deinit();
    try tp.start();

    const task_count: usize = 17;

    const Context = struct {
        tasks: std.atomic.Value(usize),

        pub fn run(self: *@This()) void {
            _ = self.tasks.fetchAdd(1, .seq_cst);
        }
    };

    var ctx = Context{ .tasks = std.atomic.Value(usize).init(0) };
    const executor = tp.executor();
    for (0..task_count) |_| {
        executor.submit(Context.run, .{&ctx}, alloc);
    }
    tp.waitIdle();
    tp.stop();
    try testing.expectEqual(task_count, ctx.tasks.load(.seq_cst));
}

test "Parallel" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(4, alloc);
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
    const executor = tp.executor();
    executor.submit(Context.Run, .{&ctx_a}, alloc);
    var ctx_b = Context{
        .tasks = &tasks,
        .sleep_nanoseconds = 0,
    };
    executor.submit(Context.Run, .{&ctx_b}, alloc);
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

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp1 = try ThreadPool.init(1, alloc);
    var tp2 = try ThreadPool.init(1, alloc);
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

    var timer = try std.time.Timer.start();

    tp1.executor().submit(Context.Run, .{&ctx}, alloc);
    tp2.executor().submit(Context.Run, .{&ctx}, alloc);

    tp2.waitIdle();
    tp2.stop();
    tp1.waitIdle();
    tp1.stop();

    const elapsed_ns = timer.read();
    try testing.expectEqual(2, tasks.load(.seq_cst));
    try testing.expect(elapsed_ns / std.time.ns_per_ms < 1500);
}

test "Stop" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(1, alloc);
    defer tp.deinit();
    try tp.start();
    const Context = struct {
        pub fn Run(_: *@This()) void {
            std.time.sleep(std.time.ns_per_ms * 128);
        }
    };
    var ctx = Context{};
    const executor = tp.executor();
    for (0..3) |_| {
        executor.submit(Context.Run, .{&ctx}, alloc);
    }
    tp.stop();
    try testing.expectEqual(0, tp.tasks.backing_queue.count);
}

test "Current" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(1, alloc);
    defer tp.deinit();
    try tp.start();
    try std.testing.expectEqual(null, ThreadPool.current());
    const Context = struct {
        tp: *ThreadPool,
        pub fn Run(self: *@This()) void {
            const c = ThreadPool.current();
            std.testing.expectEqual(self.tp, c) catch std.debug.panic(
                "Expected: {?} Got: {?}",
                .{ self.tp, c },
            );
        }
    };
    var ctx = Context{ .tp = &tp };
    const executor = tp.executor();
    executor.submit(Context.Run, .{&ctx}, alloc);
    tp.stop();
}

test "Submit after wait idle" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(1, alloc);
    defer tp.deinit();
    try tp.start();
    const ContextB = struct {
        done: *bool,
        alloc: Allocator,

        pub fn Run(self: *@This()) void {
            std.time.sleep(std.time.ns_per_ms * 500);
            self.done.* = true;
            self.alloc.destroy(self);
        }
    };
    const ContextA = struct {
        done: *bool,
        alloc: Allocator,

        pub fn Run(self: *@This()) void {
            std.time.sleep(std.time.ns_per_ms * 500);
            // must allocate on heap:
            // if we allocate on stack, then ptr to ctx will be destroyed
            // as soon as ContextA.Run exits, but before ContextB.Run accesses
            // its "self" ptr ptr, leading to segfault.
            const ctx = self.alloc.create(ContextB) catch unreachable;
            ctx.* = .{
                .done = self.done,
                .alloc = self.alloc,
            };
            ThreadPool.current().?.executor().submit(ContextB.Run, .{ctx}, self.alloc);
        }
    };
    var done = false;
    var ctx = ContextA{ .done = &done, .alloc = alloc };
    const executor = tp.executor();
    executor.submit(ContextA.Run, .{&ctx}, alloc);
    tp.waitIdle();
    tp.stop();
    try testing.expectEqual(true, done);
}

test "Use Threads" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var limit = try TimeLimit.init(std.time.ns_per_s);
    {
        var thread_safe_alloc = std.heap.ThreadSafeAllocator{
            .child_allocator = std.testing.allocator,
            .mutex = .{},
        };
        const alloc = thread_safe_alloc.allocator();

        var tp = try ThreadPool.init(4, alloc);
        defer tp.deinit();
        try tp.start();

        const task_count: usize = 4;

        const Context = struct {
            tasks: std.atomic.Value(usize),

            pub fn run(self: *@This()) void {
                std.time.sleep(std.time.ns_per_ms * 750);
                _ = self.tasks.fetchAdd(1, .seq_cst);
            }
        };

        var ctx = Context{ .tasks = std.atomic.Value(usize).init(0) };
        const executor = tp.executor();
        for (0..task_count) |_| {
            executor.submit(Context.run, .{&ctx}, alloc);
        }
        tp.waitIdle();
        tp.stop();
        try testing.expectEqual(task_count, ctx.tasks.load(.seq_cst));
    }
    try limit.check();
}

test "Too Many Threads" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var limit = try TimeLimit.init(std.time.ns_per_s * 2);
    {
        var thread_safe_alloc = std.heap.ThreadSafeAllocator{
            .child_allocator = std.testing.allocator,
            .mutex = .{},
        };
        const alloc = thread_safe_alloc.allocator();

        var tp = try ThreadPool.init(3, alloc);
        defer tp.deinit();
        try tp.start();

        const task_count: usize = 4;

        const Context = struct {
            tasks: std.atomic.Value(usize),

            pub fn run(self: *@This()) void {
                std.time.sleep(std.time.ns_per_ms * 750);
                _ = self.tasks.fetchAdd(1, .seq_cst);
            }
        };

        var ctx = Context{ .tasks = std.atomic.Value(usize).init(0) };
        const executor = tp.executor();
        for (0..task_count) |_| {
            executor.submit(Context.run, .{&ctx}, alloc);
        }
        tp.waitIdle();
        tp.stop();
        try testing.expectEqual(task_count, ctx.tasks.load(.seq_cst));
    }
    try limit.check();
}

test "Keep Alive" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var limit = try TimeLimit.init(std.time.ns_per_s * 4);
    {
        var thread_safe_alloc = std.heap.ThreadSafeAllocator{
            .child_allocator = std.testing.allocator,
            .mutex = .{},
        };
        const alloc = thread_safe_alloc.allocator();

        var tp = try ThreadPool.init(3, alloc);
        defer tp.deinit();
        try tp.start();

        const Context = struct {
            pub fn run(limit_: *TimeLimit, alloc_: Allocator) void {
                if (limit_.remaining() > std.time.ns_per_ms * 300) {
                    ThreadPool.current().?.executor().submit(@This().run, .{ limit_, alloc_ }, alloc_);
                }
            }
        };
        const executor = tp.executor();
        for (0..5) |_| {
            executor.submit(Context.run, .{ &limit, alloc }, alloc);
        }
        var timer = try std.time.Timer.start();
        tp.waitIdle();
        tp.stop();
        try testing.expect(timer.read() > std.time.ns_per_s * 3);
    }
    try limit.check();
}

test "Racy" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    var thread_safe_alloc = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
        .mutex = .{},
    };
    const alloc = thread_safe_alloc.allocator();

    var tp = try ThreadPool.init(4, alloc);
    defer tp.deinit();
    try tp.start();

    const task_count: usize = 100500;
    var sharead_counter = std.atomic.Value(usize).init(0);

    const Context = struct {
        shared_counter: *std.atomic.Value(usize),
        pub fn run(self: *@This()) void {
            const old = self.shared_counter.load(.seq_cst);
            self.shared_counter.store(old + 1, .seq_cst);
        }
    };

    var ctx = Context{
        .shared_counter = &sharead_counter,
    };
    const executor = tp.executor();
    for (0..task_count) |_| {
        executor.submit(Context.run, .{&ctx}, alloc);
    }
    tp.waitIdle();
    tp.stop();
    try testing.expect(sharead_counter.load(.seq_cst) <= task_count);
}
