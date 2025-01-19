const std = @import("std");
const time = std.time;
const testing = std.testing;
const gpa = testing.allocator;

const ThreadPool = @import("../../executors/main.zig").ThreadPools.Compute;
const WaitGroup = std.Thread.WaitGroup;
const IoDispatch = @import("../dispatch.zig");
const TimeLimit = @import("../../testing/TimeLimit.zig");

test "io dispatch - timer - basic" {
    const runs = 10;
    for (0..runs) |_| {
        const timer_value_ns = std.time.ns_per_ms * 1;
        const limit_value = timer_value_ns * 2;
        var time_limit = try TimeLimit.init(limit_value);
        var thread_pool = try ThreadPool.init(1, gpa);
        var wait_group: WaitGroup = .{};
        defer thread_pool.deinit();
        try thread_pool.start();
        defer thread_pool.stop();

        var dispatch = try IoDispatch.init(
            .{ .callback_entry_allocator = gpa },
            thread_pool.executor(),
            gpa,
        );
        defer dispatch.deinit();

        const Ctx = struct {
            step: usize = 0,
            wait_group: *WaitGroup,
            pub fn run(self_: ?*anyopaque) void {
                var self = @as(*@This(), @alignCast(@ptrCast(self_)));
                self.step += 1;
                self.wait_group.finish();
            }
        };

        var ctx = Ctx{ .wait_group = &wait_group };

        wait_group.start();
        try dispatch.timer(
            timer_value_ns,
            Ctx.run,
            .{&ctx},
        );
        wait_group.wait();
        try time_limit.check();
        try testing.expect(time_limit.remaining() <= timer_value_ns);
        try testing.expectEqual(1, ctx.step);
    }
}

test "io dispatch - timer - multiple" {
    const timer_count = 3;
    const timer_step_ns = std.time.ns_per_s;
    var thread_pool = try ThreadPool.init(1, gpa);
    defer thread_pool.deinit();
    try thread_pool.start();
    defer thread_pool.stop();

    var dispatch = try IoDispatch.init(
        .{ .callback_entry_allocator = gpa },
        thread_pool.executor(),
        gpa,
    );
    defer dispatch.deinit();

    const Ctx = struct {
        step: usize = 0,
        wait_group: WaitGroup = .{},
        pub fn run(self_: ?*anyopaque) void {
            var self = @as(*@This(), @alignCast(@ptrCast(self_)));
            self.step += 1;
            self.wait_group.finish();
        }
    };

    var ctx = Ctx{};

    for (0..timer_count) |i| {
        ctx.wait_group.start();
        try dispatch.timer(
            timer_step_ns * i + 1,
            Ctx.run,
            .{&ctx},
        );
    }
    std.Thread.sleep(timer_count * timer_step_ns);
    try testing.expectEqual(timer_count, ctx.step);
}
