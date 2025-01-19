const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const build_config = @import("build_config");

const Fiber = @import("../../main.zig");
const Mutex = Fiber.Mutex;

const Executors = @import("../../../executors/main.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const WaitGroup = std.Thread.WaitGroup;
const TimeLimit = @import("../../../testing/TimeLimit.zig");

test "counter" {
    var mutex: Mutex = .{};
    var manual_executor = ManualExecutor{};
    const count: usize = 100;
    const Ctx = struct {
        mutex: *Mutex,
        counter: usize,

        pub fn run(self: *@This()) void {
            for (0..count) |_| {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.counter += 1;
            }
        }
    };
    var ctx: Ctx = .{
        .mutex = &mutex,
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

test "TryLock" {
    var mutex: Mutex = .{};
    var manual_executor = ManualExecutor{};
    const Ctx = struct {
        mutex: *Mutex,
        counter: usize,

        pub fn run(self: *@This()) !void {
            {
                try testing.expect(self.mutex.tryLock());
                defer self.mutex.unlock();
            }
            {
                self.mutex.lock();
                self.mutex.unlock();
            }
            try testing.expect(self.mutex.tryLock());

            var join: bool = false;
            const Outer = @This();
            const Inner = struct {
                pub fn run(join_: *bool, outer: *Outer) !void {
                    try testing.expect(!outer.mutex.tryLock());
                    join_.* = true;
                }
            };

            try Fiber.go(
                Inner.run,
                .{ &join, self },
                testing.allocator,
                Fiber.current().?.executor,
            );

            //hack - for testing only -
            Fiber.current().?.endSuspendIllegalScope();

            while (!join) {
                Fiber.yield();
            }
            //hack - for testing only -
            Fiber.current().?.beginSuspendIllegalScope();
            self.mutex.unlock();
        }
    };
    var ctx: Ctx = .{
        .mutex = &mutex,
        .counter = 0,
    };
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    _ = manual_executor.drain();
}

test "inner counter" {
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var mutex: Mutex = .{};
    var manual_executor = ManualExecutor{};
    const iterations_per_fiber = 5;
    const fiber_count = 5;
    var counter: usize = 0;
    const Ctx = struct {
        mutex: *Mutex,
        counter: *usize,

        pub fn run(self: *@This()) void {
            for (0..iterations_per_fiber) |_| {
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.counter.* += 1;
                }
                Fiber.yield();
            }
        }
    };
    var ctx: Ctx = .{
        .mutex = &mutex,
        .counter = &counter,
    };
    for (0..fiber_count) |_| {
        try Fiber.go(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            manual_executor.executor(),
        );
    }
    _ = manual_executor.drain();
    try testing.expectEqual(
        fiber_count * iterations_per_fiber,
        counter,
    );
}

test "threadpool" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Ctx = struct {
        mutex: Mutex = .{},
        counter: usize = 0,
        wait_group: WaitGroup = .{},

        pub fn run(ctx: *@This()) void {
            ctx.mutex.lock();
            ctx.counter += 1;
            ctx.mutex.unlock();
            ctx.wait_group.finish();
        }
    };

    var ctx = Ctx{};

    for (0..3) |_| {
        ctx.wait_group.start();
        try Fiber.go(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }
    ctx.wait_group.wait();
}

test "threadpool - parallel" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var limit = try TimeLimit.init(std.time.ns_per_s * 5);
    {
        var tp = try ThreadPool.init(4, testing.allocator);
        defer tp.deinit();
        try tp.start();
        defer tp.stop();

        const Ctx = struct {
            mutex: Mutex = .{},
            wait_group: WaitGroup = .{},

            pub fn run1(ctx: *@This()) void {
                ctx.mutex.lock();
                std.Thread.sleep(std.time.ns_per_s);
                ctx.mutex.unlock();
                ctx.wait_group.finish();
            }
            pub fn run2(ctx: *@This()) void {
                ctx.mutex.lock();
                ctx.mutex.unlock();
                std.Thread.sleep(std.time.ns_per_s);
                ctx.wait_group.finish();
            }
        };
        var ctx: Ctx = .{};
        ctx.wait_group.start();
        try Fiber.go(
            Ctx.run1,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );

        for (0..3) |_| {
            ctx.wait_group.start();
            try Fiber.go(
                Ctx.run2,
                .{&ctx},
                testing.allocator,
                tp.executor(),
            );
        }
        ctx.wait_group.wait();
    }
    try limit.check();
}

test "Suspend Illegal" {
    var manual_executor = ManualExecutor{};
    const Ctx = struct {
        mutex: Mutex = .{},

        pub fn run(self: *@This()) !void {
            self.mutex.lock();
            try self.criticalSection();
            self.mutex.unlock();
        }

        pub fn criticalSection(self: *@This()) !void {
            _ = self;
            try testing.expect(Fiber.current().?.inSuspendIllegalScope());
            // illegal
            // Fiber.yield();
        }
    };
    var ctx: Ctx = .{};
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        testing.allocator,
        manual_executor.executor(),
    );
    _ = manual_executor.drain();
}
