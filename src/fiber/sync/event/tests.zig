const builtin = @import("builtin");
const std = @import("std");
const build_config = @import("build_config");
const testing = std.testing;
const fault = @import("../../../fault/main.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const Event = Fiber.Event;
const Fiber = @import("../../main.zig");

const Executors = @import("../../../executors/main.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const WaitGroup = std.Thread.WaitGroup;

const TimeLimit = @import("../../../testing/TimeLimit.zig");

test "basic - single waiter" {
    var event: Event = .{};
    var manual_executor = ManualExecutor{};
    var state: bool = false;
    const Ctx = struct {
        event: *Event,
        state: *bool,

        pub fn runConsumer(self: *@This()) !void {
            self.event.wait();
            try testing.expect(self.state.*);
        }

        pub fn runProducer(self: *@This()) !void {
            self.state.* = true;
            self.event.fire();
        }
    };
    var ctx: Ctx = .{
        .event = &event,
        .state = &state,
    };
    try Fiber.go(
        Ctx.runConsumer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    try Fiber.go(
        Ctx.runProducer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    _ = manual_executor.drain();
    try testing.expect(state);
}

test "event - basic - multiple waiters" {
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var event: Event = .{};
    var manual_executor = ManualExecutor{};
    var state: bool = false;
    var counter: usize = 0;
    const workers = 4;
    const Ctx = struct {
        event: *Event,
        state: *bool,
        counter: *usize,

        pub fn runProducer(self: *@This()) !void {
            self.state.* = true;
            self.event.fire();
        }

        pub fn runConsumer(self: *@This()) !void {
            self.event.wait();
            try testing.expect(self.state.*);
            self.counter.* += 1;
        }
    };
    var ctx: Ctx = .{
        .event = &event,
        .state = &state,
        .counter = &counter,
    };
    for (0..workers - 1) |_| {
        try Fiber.go(
            Ctx.runConsumer,
            .{&ctx},
            testing.allocator,
            manual_executor.executor(),
        );
    }
    try Fiber.go(
        Ctx.runProducer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );

    try Fiber.go(
        Ctx.runConsumer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    _ = manual_executor.drain();
    try testing.expectEqual(true, state);
    try testing.expectEqual(workers, counter);
}

test "park fiber while waiting" {
    var event: Event = .{};
    var manual_executor = ManualExecutor{};
    var state: bool = false;
    const Ctx = struct {
        event: *Event,
        state: *bool,

        pub fn runConsumer(self: *@This()) !void {
            self.event.wait();
            try testing.expect(self.state.*);
        }

        pub fn runProducer(self: *@This()) !void {
            self.state.* = true;
            self.event.fire();
        }
    };
    var ctx: Ctx = .{
        .event = &event,
        .state = &state,
    };
    try Fiber.go(
        Ctx.runConsumer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    const task_count = manual_executor.drain();
    try testing.expect(task_count < 7);
    try Fiber.go(
        Ctx.runProducer,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    _ = manual_executor.drain();
    try testing.expect(state);
}

test "event - threadpool - stress" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();
    var wait_group: WaitGroup = .{};
    const Ctx = struct {
        event: Event = .{},
        state: Atomic(bool) = .init(false),
        alloc: std.mem.Allocator,
        wait_group: *WaitGroup,

        pub fn runConsumer(self: *@This()) !void {
            var wg = self.wait_group;
            self.event.wait();
            try testing.expectEqual(true, self.state.load(.seq_cst));
            wg.finish();
        }

        pub fn runProducer(self: *@This()) !void {
            self.state.store(true, .seq_cst);
            self.event.fire();
            self.wait_group.finish();
        }
    };
    const runs = 5;
    for (0..runs) |_| {
        var ctx: Ctx = .{
            .alloc = testing.allocator,
            .wait_group = &wait_group,
        };
        const consumers = 1000;
        for (0..consumers / 2) |_| {
            ctx.wait_group.start();
            try Fiber.go(
                Ctx.runConsumer,
                .{&ctx},
                testing.allocator,
                tp.executor(),
            );
        }

        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.runProducer,
            .{&ctx},
            testing.allocator,
            tp.executor(),
            .{ .stack_size = 1024 * 16 },
        );

        for (0..consumers / 2) |_| {
            ctx.wait_group.start();
            try Fiber.goOptions(
                Ctx.runConsumer,
                .{&ctx},
                testing.allocator,
                tp.executor(),
                .{ .stack_size = 1024 * 16 },
            );
        }
        wait_group.wait();
        wait_group.reset();
    }
}
