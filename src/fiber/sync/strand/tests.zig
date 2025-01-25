const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const build_config = @import("build_config");

const fault = @import("../../../fault/main.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const Fiber = @import("../../main.zig");
const Strand = Fiber.Strand;
const Event = Fiber.Event;

const Executors = @import("../../../executors/main.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const WaitGroup = std.Thread.WaitGroup;
const TimeLimit = @import("../../../testing/TimeLimit.zig");

test "strand - counter" {
    var strand: Strand = .{};
    var manual_executor = ManualExecutor{};
    const count: usize = 100;
    const Ctx = struct {
        strand: *Strand,
        counter: usize,

        pub fn run(self: *@This()) void {
            for (0..count) |_| {
                self.strand.combine(criticalSection, .{self});
            }
        }

        pub fn criticalSection(self: *@This()) void {
            self.counter += 1;
        }
    };
    var ctx: Ctx = .{
        .strand = &strand,
        .counter = 0,
    };
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    _ = manual_executor.drain();
    try testing.expectEqual(count, ctx.counter);
}

test "strand - many fibers" {
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var strand: Strand = .{};
    var manual_executor = ManualExecutor{};
    const count: usize = 100;
    const Ctx = struct {
        strand: *Strand,
        counter: usize,

        pub fn run(self: *@This()) void {
            for (0..count) |_| {
                self.strand.combine(criticalSection, .{self});
            }
        }

        pub fn criticalSection(self: *@This()) void {
            self.counter += 1;
        }
    };
    var ctx: Ctx = .{
        .strand = &strand,
        .counter = 0,
    };
    const fiber_count = 5;
    for (0..fiber_count) |_| {
        try Fiber.go(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            manual_executor.executor(),
        );
    }
    _ = manual_executor.drain();
    try testing.expectEqual(count * fiber_count, ctx.counter);
}

test "strand - run on single fiber" {
    var strand: Strand = .{};
    var manual_executor = ManualExecutor{};
    var fiber_name: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES:0]u8 = undefined;
    const Ctx = struct {
        strand: *Strand,

        pub fn run(self: *@This(), i: usize) void {
            self.strand.combine(criticalSection, .{i});
        }

        pub fn criticalSection(i: usize) !void {
            try testing.expectEqual(0, i);
        }
    };
    var ctx: Ctx = .{
        .strand = &strand,
    };
    for (0..1) |i| {
        const name = try std.fmt.bufPrintZ(
            fiber_name[0..],
            "Fiber #{}",
            .{i},
        );
        try Fiber.goOptions(
            Ctx.run,
            .{ &ctx, i },
            testing.allocator,
            manual_executor.executor(),
            .{
                .fiber = .{ .name = name },
            },
        );
    }
    _ = manual_executor.drain();
}

test "strand - suspend illegal" {
    var strand: Strand = .{};
    var event: Event = .{};
    var manual_executor = ManualExecutor{};
    const Ctx = struct {
        strand: *Strand,
        event: *Event,

        pub fn run(self: *@This()) void {
            self.strand.combine(criticalSection, .{self});
        }

        pub fn criticalSection(self: *@This()) !void {
            _ = self;
            try testing.expect(Fiber.current().?.inSuspendIllegalScope());
            // illegal
            // self.event.wait();
        }
    };
    var ctx: Ctx = .{
        .strand = &strand,
        .event = &event,
    };
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    _ = manual_executor.drain();
}

test "strand - thread pool" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();
    var fiber_name: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES:0]u8 = undefined;
    const iterations_per_fiber = 3;
    const fiber_count = 5;
    const Ctx = struct {
        strand: Strand = .{},
        counter: usize,
        control: Atomic(usize),
        wait_group: WaitGroup = .{},

        pub fn run(self: *@This()) void {
            for (0..iterations_per_fiber) |_| {
                _ = self.control.fetchAdd(1, .monotonic);
                self.strand.combine(criticalSection, .{self});
            }
            self.wait_group.finish();
        }

        pub fn criticalSection(self: *@This()) !void {
            self.counter += 1;
        }
    };
    var ctx: Ctx = .{
        .counter = 0,
        .control = .init(0),
    };
    ctx.wait_group.startMany(fiber_count);
    for (0..fiber_count) |i| {
        const name = try std.fmt.bufPrintZ(
            fiber_name[0..],
            "Fiber #{}",
            .{i},
        );
        try Fiber.goOptions(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            tp.executor(),
            .{
                .fiber = .{ .name = name },
                .stack_size = 1024 * 16 * 16,
            },
        );
    }
    ctx.wait_group.wait();
    try testing.expectEqual(
        ctx.control.load(.monotonic),
        ctx.counter,
    );
}

test "strand - stress" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }

    const cpu_count = try std.Thread.getCpuCount();
    const runs = 10;
    for (0..runs) |_| {
        var tp = try ThreadPool.init(cpu_count, testing.allocator);
        defer tp.deinit();
        try tp.start();
        defer tp.stop();
        var fiber_name: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES:0]u8 = undefined;
        const iterations_per_fiber = 100;
        const fiber_count = 100;
        const Ctx = struct {
            strand: Strand = .{},
            counter: usize,
            control: Atomic(usize),
            wait_group: WaitGroup = .{},

            pub fn run(self: *@This()) void {
                for (0..iterations_per_fiber) |_| {
                    _ = self.control.fetchAdd(1, .monotonic);
                    self.strand.combine(criticalSection, .{self});
                }
                self.wait_group.finish();
            }

            pub fn criticalSection(self: *@This()) !void {
                self.counter += 1;
            }
        };
        var ctx: Ctx = .{
            .counter = 0,
            .control = .init(0),
        };
        ctx.wait_group.startMany(fiber_count);
        for (0..fiber_count) |i| {
            const name = try std.fmt.bufPrintZ(
                fiber_name[0..],
                "Fiber #{}",
                .{i},
            );
            try Fiber.goOptions(
                Ctx.run,
                .{&ctx},
                testing.allocator,
                tp.executor(),
                .{
                    .fiber = .{ .name = name },
                    .stack_size = 1024 * 16 * 16,
                },
            );
        }
        ctx.wait_group.wait();
        try testing.expectEqual(
            ctx.control.load(.monotonic),
            ctx.counter,
        );
    }
}
