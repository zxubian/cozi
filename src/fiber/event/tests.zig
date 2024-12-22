const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Atomic = std.atomic.Value;

const Event = Fiber.Event;
const Fiber = @import("../../fiber.zig");

const Executors = @import("../../executors.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const WaitGroup = std.Thread.WaitGroup;

const TimeLimit = @import("../../testing/TimeLimit.zig");

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

test "basic - multiple waiters" {
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

test "threadpool - stress" {
    if (builtin.single_threaded) {
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
            self.alloc.destroy(self);
            wg.finish();
        }

        pub fn runProducer(self: *@This()) !void {
            self.state.store(true, .seq_cst);
            self.event.fire();
            self.wait_group.finish();
        }
    };
    for (0..1000) |_| {
        const ctx = try testing.allocator.create(Ctx);
        ctx.* = .{
            .alloc = testing.allocator,
            .wait_group = &wait_group,
        };
        ctx.wait_group.startMany(2);
        try Fiber.go(
            Ctx.runConsumer,
            .{ctx},
            testing.allocator,
            tp.executor(),
        );
        try Fiber.go(
            Ctx.runProducer,
            .{ctx},
            testing.allocator,
            tp.executor(),
        );
    }
    wait_group.wait();
}
