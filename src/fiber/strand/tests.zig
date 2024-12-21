const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const Atomic = std.atomic.Value;

const Fiber = @import("../../fiber.zig");
const Strand = Fiber.Strand;
const Event = Fiber.Event;

const Executors = @import("../../executors.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const TimeLimit = @import("../../testing/TimeLimit.zig");

test "counter" {
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

test "many fibers" {
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

test "run on single fiber" {
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
                .name = name,
            },
        );
    }
    _ = manual_executor.drain();
}

test "Suspend Illegal" {
    var strand: Strand = .{};
    var event: Event = .{};
    var manual_executor = ManualExecutor{};
    const Ctx = struct {
        strand: *Strand,
        event: *Event,

        pub fn run(self: *@This()) void {
            self.strand.combine(criticalSection, .{self});
        }

        pub fn criticalSection(_: *@This()) !void {
            try testing.expect(Fiber.current().?.suspend_illegal_scope != null);
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

test "stress" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    const runs = 5;
    for (0..runs) |_| {
        var strand: Strand = .{};
        var tp = try ThreadPool.init(cpu_count, testing.allocator);
        defer tp.deinit();
        try tp.start();
        defer tp.stop();
        var fiber_name: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES:0]u8 = undefined;
        const iterations_per_fiber = 100;
        const fiber_count = 100;
        const rand = std.Random.DefaultPrng.init(std.testing.random_seed);
        const Ctx = struct {
            strand: *Strand,
            counter: usize,
            control: Atomic(usize),
            rand: std.Random.DefaultPrng,

            fn randomRange(self: *@This(), comptime max: usize) usize {
                const r: usize = self.rand.next();
                return @intFromFloat(@as(f64, @floatFromInt(r)) / std.math.maxInt(@TypeOf(r)) * max);
            }

            pub fn run(self: *@This()) void {
                for (0..iterations_per_fiber) |_| {
                    _ = self.control.fetchAdd(1, .monotonic);
                    std.Thread.sleep(self.randomRange(3) * std.time.ns_per_ms);
                    self.strand.combine(criticalSection, .{self});
                }
            }

            pub fn criticalSection(self: *@This()) !void {
                std.Thread.sleep(self.randomRange(3) * std.time.ns_per_us);
                self.counter += 1;
            }
        };
        var ctx: Ctx = .{
            .strand = &strand,
            .counter = 0,
            .control = .init(0),
            .rand = rand,
        };
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
                    .name = name,
                },
            );
        }
        _ = tp.waitIdle();
        try testing.expectEqual(
            ctx.control.load(.monotonic),
            ctx.counter,
        );
    }
}
