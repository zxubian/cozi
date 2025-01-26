const std = @import("std");
const log = std.log.scoped(.fiber_channel);
const testing = std.testing;
const fault_injection_builtin = @import("zig_async_fault_injection");

const Fiber = @import("../../main.zig");
const select = Fiber.select;

const Executors = @import("../../../executors/main.zig");
const ManualExecutor = Executors.Manual;

test "Select - send then select receive" {
    if (fault_injection_builtin.build_variant == .fiber) {
        return error.SkipZigTest;
    }
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This(), value: usize) !void {
            ctx.channel_a.send(value);
            ctx.sender_done = true;
        }

        pub fn receiver(
            ctx: *@This(),
            expected: usize,
        ) !void {
            const result = select(usize)(
                &ctx.channel_a,
                &ctx.channel_b,
            );
            try testing.expectEqual(expected, result);
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.sender,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.receiver,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(ctx.receiver_done);
}

test "Select - send multiple then select receive" {
    if (fault_injection_builtin.build_variant == .fiber) {
        return error.SkipZigTest;
    }
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_a_done: bool = false,
        sender_b_done: bool = false,
        receiver_done: bool = false,

        pub fn senderA(ctx: *@This(), value: usize) !void {
            ctx.channel_a.send(value);
            ctx.sender_a_done = true;
        }

        pub fn senderB(ctx: *@This(), value: usize) !void {
            ctx.channel_b.send(value);
            ctx.sender_b_done = true;
        }

        pub fn receiver(
            ctx: *@This(),
        ) !void {
            _ = select(usize)(
                &ctx.channel_a,
                &ctx.channel_b,
            );
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.senderA,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    try Fiber.go(
        Ctx.senderB,
        .{ &ctx, 2 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(!ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.receiver,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(!ctx.sender_a_done or !ctx.sender_b_done);
    try testing.expect(ctx.receiver_done);
    ctx.receiver_done = false;

    try Fiber.go(
        Ctx.receiver,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(ctx.receiver_done);
}

test "Select - select receive then send" {
    if (fault_injection_builtin.build_variant == .fiber) {
        return error.SkipZigTest;
    }
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This(), value: usize) !void {
            ctx.channel_a.send(value);
            ctx.sender_done = true;
        }

        pub fn receiver(
            ctx: *@This(),
            expected: usize,
        ) !void {
            const result = select(usize)(
                &ctx.channel_a,
                &ctx.channel_b,
            );
            try testing.expectEqual(expected, result);
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.receiver,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.sender,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(ctx.receiver_done);
}

test "Select - clear awaiters from queues of unused fibers after select is resolved" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_a_done: bool = false,
        sender_b_done: bool = false,
        selector_done: bool = false,
        receiver_done: bool = false,

        pub fn senderA(ctx: *@This()) !void {
            ctx.channel_a.send(1);
            ctx.sender_a_done = true;
        }

        pub fn senderB(ctx: *@This()) !void {
            ctx.channel_b.send(2);
            ctx.sender_b_done = true;
        }

        pub fn selector(
            ctx: *@This(),
            expected: usize,
        ) !void {
            const result = select(usize)(
                &ctx.channel_a,
                &ctx.channel_b,
            );
            try testing.expectEqual(expected, result);
            ctx.selector_done = true;
        }

        pub fn receiver(
            ctx: *@This(),
            channel: *Fiber.Channel(usize),
            expected: usize,
        ) !void {
            const result = channel.receive();
            try testing.expectEqual(expected, result);
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.selector,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );

    _ = manual.drain();
    try testing.expect(!ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.senderA,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);
    try testing.expect(ctx.selector_done);

    try Fiber.go(
        Ctx.senderB,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);
    try testing.expect(ctx.selector_done);

    try Fiber.go(
        Ctx.receiver,
        .{ &ctx, &ctx.channel_b, 2 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(ctx.receiver_done);
    try testing.expect(ctx.selector_done);
}

test "Select - select in loop" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_a_done: bool = false,
        sender_b_done: bool = false,
        receiver_done: bool = false,

        pub fn senderA(ctx: *@This()) !void {
            ctx.channel_a.send(1);
            ctx.sender_a_done = true;
        }

        pub fn senderB(ctx: *@This()) !void {
            ctx.channel_b.send(2);
            ctx.sender_b_done = true;
        }

        pub fn receiver(
            ctx: *@This(),
            expected: [2]usize,
        ) !void {
            for (expected) |e| {
                const result = select(usize)(
                    &ctx.channel_a,
                    &ctx.channel_b,
                );
                try testing.expectEqual(e, result);
            }
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.receiver,
        .{ &ctx, [_]usize{ 2, 1 } },
        testing.allocator,
        manual.executor(),
    );

    _ = manual.drain();
    try testing.expect(!ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.senderB,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(!ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.senderA,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try testing.expect(ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(ctx.receiver_done);
}

test "Select - select in loop - send first" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_a_done: bool = false,
        sender_b_done: bool = false,
        receiver_done: bool = false,

        pub fn senderA(ctx: *@This()) !void {
            ctx.channel_a.send(1);
            ctx.sender_a_done = true;
        }

        pub fn senderB(ctx: *@This()) !void {
            ctx.channel_b.send(2);
            ctx.sender_b_done = true;
        }

        pub fn receiver(
            ctx: *@This(),
            expected: [2]usize,
        ) !void {
            for (0..expected.len) |_| {
                const result = select(usize)(
                    &ctx.channel_a,
                    &ctx.channel_b,
                );
                try testing.expect(std.mem.indexOfScalar(usize, &expected, result.?) != null);
            }
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.senderA,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(!ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.senderB,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(!ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.receiver,
        .{ &ctx, [_]usize{ 2, 1 } },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(ctx.receiver_done);
}
