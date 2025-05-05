const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const allocator = std.testing.allocator;

const cozi = @import("../../root.zig");
const executors = cozi.executors;
const ManualExecutor = executors.Manual;
const Executor = executors.Executor;
const core = cozi.core;
const Runnable = core.Runnable;
const Fiber = cozi.Fiber;

test "Just Works" {
    var manual = ManualExecutor{};
    var step: usize = 0;
    try testing.expect(manual.isEmpty());
    try testing.expect(!manual.runNext());
    try testing.expectEqual(0, manual.runAtMost(99));

    const Step = struct {
        pub fn run(step_: *usize) void {
            step_.* += 1;
        }
    };
    const executor = manual.executor();
    executor.submit(Step.run, .{&step}, allocator);
    try testing.expect(!manual.isEmpty());
    try testing.expectEqual(1, manual.count());
    try testing.expectEqual(0, step);
    executor.submit(Step.run, .{&step}, allocator);
    try testing.expectEqual(2, manual.count());
    try testing.expectEqual(0, step);
    try testing.expect(manual.runNext());
    try testing.expectEqual(1, step);
    executor.submit(Step.run, .{&step}, allocator);
    try testing.expectEqual(2, manual.count());
    try testing.expectEqual(2, manual.runAtMost(99));
    try testing.expectEqual(3, step);
    try testing.expect(manual.isEmpty());
    try testing.expect(!manual.runNext());
}

test "Run At Most" {
    var manual = ManualExecutor{};
    try testing.expect(manual.isEmpty());
    try testing.expect(!manual.runNext());
    try testing.expectEqual(0, manual.runAtMost(99));

    const Looper = struct {
        iterations: usize,
        manual: *ManualExecutor,
        allocator: Allocator,

        pub fn run(self: *@This()) void {
            self.iterations -= 1;
            if (self.iterations > 0) {
                self.submit();
            }
        }

        fn submit(self: *@This()) void {
            self.manual.executor().submit(@This().run, .{self}, self.allocator);
        }

        pub fn start(self: *@This()) void {
            self.submit();
        }
    };

    var looper = Looper{
        .iterations = 256,
        .manual = &manual,
        .allocator = allocator,
    };
    looper.start();

    var step: usize = 0;
    while (!manual.isEmpty()) {
        step += manual.runAtMost(7);
    }
    try testing.expectEqual(256, step);
}

test "Drain" {
    var manual = ManualExecutor{};

    const Looper = struct {
        iterations: usize,
        manual: *ManualExecutor,
        allocator: Allocator,

        pub fn run(self: *@This()) void {
            self.iterations -= 1;
            if (self.iterations > 0) {
                self.submit();
            }
        }

        fn submit(self: *@This()) void {
            self.manual.executor().submit(@This().run, .{self}, self.allocator);
        }

        pub fn start(self: *@This()) void {
            self.submit();
        }
    };

    var looper = Looper{
        .iterations = 117,
        .manual = &manual,
        .allocator = allocator,
    };
    looper.start();
    try testing.expectEqual(117, manual.drain());
}

test "executors - event loop - basic" {
    var event_loop: ManualExecutor = .{};
    const executor = event_loop.executor();
    var stage: usize = 0;
    executor.submit(
        struct {
            pub fn run(
                stage_: *usize,
                executor_: Executor,
                allocator_: std.mem.Allocator,
            ) void {
                stage_.* += 1;
                executor_.submit(@This().finish, .{stage_}, allocator_);
            }

            pub fn finish(stage_: *usize) void {
                stage_.* += 1;
            }
        }.run,
        .{ &stage, executor, testing.allocator },
        testing.allocator,
    );
    try testing.expectEqual(0, stage);
    _ = event_loop.runBatch();
    try testing.expectEqual(1, stage);
    _ = event_loop.runBatch();
    try testing.expectEqual(2, stage);
}

test "executors - manual - event loop - fiber" {
    var event_loop: ManualExecutor = .{};
    const executor = event_loop.executor();
    const fiber_count = 2;
    const iteration_count = 100;
    const Ctx = struct {
        progress: [fiber_count]usize = [_]usize{0} ** fiber_count,

        pub fn fiber(idx: usize, ctx: *@This()) void {
            for (0..iteration_count) |_| {
                ctx.progress[idx] += 1;
                Fiber.yield();
            }
        }
    };
    var ctx: Ctx = .{};
    for (0..fiber_count) |fiber_idx| {
        try Fiber.goWithNameFmt(
            Ctx.fiber,
            .{
                fiber_idx,
                &ctx,
            },
            testing.allocator,
            executor,
            "Fiber #{}",
            .{fiber_idx},
        );
    }
    for (0..iteration_count) |i| {
        for (0..fiber_count) |fiber_idx| {
            try testing.expectEqual(ctx.progress[fiber_idx], i);
        }
        try testing.expectEqual(2, event_loop.runBatch());
    }
    try testing.expectEqual(2, event_loop.runBatch());
}
