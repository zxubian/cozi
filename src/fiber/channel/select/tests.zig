const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.fiber_channel);
const testing = std.testing;
const fault_injection_builtin = @import("zig_async_fault_injection");

const Fiber = @import("../../main.zig");
const Select = Fiber.select;
const Channel = Fiber.Channel;

const Executors = @import("../../../executors/main.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;

const fault = @import("../../../fault/main.zig");
const Atomic = fault.stdlike.atomic;

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
            const result = Select(usize)(
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
            _ = Select(usize)(
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
            const result = Select(usize)(
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
            const result = Select(usize)(
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
                const result = Select(usize)(
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
                const result = Select(usize)(
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

test "Select - do not block on closed channel" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_a_done: bool = false,
        sender_b_done: bool = false,
        receiver_done: bool = false,
        selector_done: bool = false,

        pub fn senderA(ctx: *@This()) !void {
            ctx.channel_a.close();
            ctx.sender_a_done = true;
        }

        pub fn senderB(ctx: *@This()) !void {
            ctx.channel_b.send(2);
            ctx.channel_b.close();
            ctx.sender_b_done = true;
        }

        pub fn selector(
            ctx: *@This(),
            expected: []const ?usize,
        ) !void {
            for (expected) |e| {
                const result = Select(usize)(
                    &ctx.channel_a,
                    &ctx.channel_b,
                );
                try testing.expectEqual(e, result);
            }
            ctx.selector_done = true;
        }

        pub fn receiver(
            ctx: *@This(),
            channel: *Fiber.Channel(usize),
            expected: []const ?usize,
        ) !void {
            for (expected) |e| {
                const result = channel.receive();
                try testing.expectEqual(e, result);
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
    try testing.expect(ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.selector,
        .{ &ctx, &[_]?usize{null} },
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
        .{ &ctx, &ctx.channel_b, &[_]?usize{ 2, null } },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(ctx.receiver_done);
    try testing.expect(ctx.selector_done);
}

test "Select - channel close must resume fiber which was parked on select" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_done: []bool,
        selector_done: bool = false,

        pub fn sender(
            ctx: *@This(),
            idx: usize,
            channel: *Fiber.Channel(usize),
            values: []const usize,
        ) !void {
            for (values) |value| {
                channel.send(value);
            }
            channel.close();
            ctx.sender_done[idx] = true;
        }

        pub fn selector(
            ctx: *@This(),
            expected: []const ?usize,
        ) !void {
            for (expected) |e| {
                const result = Select(usize)(
                    &ctx.channel_a,
                    &ctx.channel_b,
                );
                try testing.expectEqual(e, result);
            }
            ctx.selector_done = true;
        }

        pub fn allSendersDone(self: *@This()) bool {
            for (self.sender_done) |done| {
                if (!done) return false;
            }
            return true;
        }
    };

    var sender_done: [1]bool = undefined;
    for (&sender_done) |*done| {
        done.* = false;
    }
    var ctx: Ctx = .{
        .sender_done = &sender_done,
    };

    try Fiber.go(
        Ctx.selector,
        .{ &ctx, &[_]?usize{null} },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(!ctx.allSendersDone());
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.sender,
        .{ &ctx, 0, &ctx.channel_a, &[_]usize{} },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(ctx.allSendersDone());
    try testing.expect(ctx.selector_done);
}

test "Select - Random polling order" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel_a: Fiber.Channel(usize) = .{},
        channel_b: Fiber.Channel(usize) = .{},
        sender_a_done: bool = false,
        sender_b_done: bool = false,
        selector_done: bool = false,

        pub fn senderA(ctx: *@This()) void {
            ctx.channel_a.close();
            ctx.sender_a_done = true;
        }

        pub fn senderB(ctx: *@This(), value: usize) void {
            ctx.channel_b.send(value);
            ctx.sender_b_done = true;
        }

        pub fn selector(
            ctx: *@This(),
            expected: usize,
        ) !void {
            const max_tries: usize = 1000000;
            const success = for (0..max_tries) |_| {
                const result =
                    Select(usize)(
                    &ctx.channel_a,
                    &ctx.channel_b,
                );
                if (result) |r| {
                    try testing.expectEqual(expected, r);
                    break true;
                }
            } else false;
            try testing.expect(success);
            ctx.selector_done = true;
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
    try testing.expect(ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.senderB,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(ctx.sender_a_done);
    try testing.expect(!ctx.sender_b_done);
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.selector,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(ctx.selector_done);
}

test "Select - receive then select receive" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channels: [2]Fiber.Channel(usize) = [_]Fiber.Channel(usize){.{}} ** 2,
        selector_done: bool = false,

        pub fn send(
            ctx: *@This(),
            channel_idx: usize,
            value: usize,
        ) void {
            ctx.channels[channel_idx].send(value);
        }

        pub fn receive(
            ctx: *@This(),
            channel_idx: usize,
            expected_value: usize,
        ) !void {
            try testing.expectEqual(expected_value, ctx.channels[channel_idx].receive());
        }

        pub fn select(
            ctx: *@This(),
            expected_value: ?usize,
        ) !void {
            try testing.expectEqual(expected_value, Select(usize)(&ctx.channels[0], &ctx.channels[1]));
            ctx.selector_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.receive,
        .{ &ctx, 0, 0 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try Fiber.go(
        Ctx.select,
        .{ &ctx, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.send,
        .{ &ctx, 0, 0 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();

    try Fiber.go(
        Ctx.send,
        .{ &ctx, 1, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
}

test "Select - select receive then receive" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channels: [2]Fiber.Channel(usize) = [_]Fiber.Channel(usize){.{}} ** 2,
        selector_done: bool = false,

        pub fn send(
            ctx: *@This(),
            channel_idx: usize,
            value: usize,
        ) void {
            ctx.channels[channel_idx].send(value);
        }

        pub fn receive(
            ctx: *@This(),
            channel_idx: usize,
            expected_value: usize,
        ) !void {
            try testing.expectEqual(expected_value, ctx.channels[channel_idx].receive());
        }

        pub fn select(
            ctx: *@This(),
            expected_value: ?usize,
        ) !void {
            try testing.expectEqual(expected_value, Select(usize)(&ctx.channels[0], &ctx.channels[1]));
            ctx.selector_done = true;
        }
    };

    var ctx: Ctx = .{};

    try Fiber.go(
        Ctx.select,
        .{ &ctx, 0 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.receive,
        .{ &ctx, 1, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(!ctx.selector_done);

    try Fiber.go(
        Ctx.send,
        .{ &ctx, 0, 0 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(ctx.selector_done);

    try Fiber.go(
        Ctx.send,
        .{ &ctx, 1, 1 },
        testing.allocator,
        manual.executor(),
    );
    _ = manual.drain();
    try testing.expect(ctx.selector_done);
}

// test "Select - stress" {
//     if (builtin.single_threaded) {
//         return error.SkipZigTest;
//     }
//     const cpu_count = try std.Thread.getCpuCount();
//     var tp: ThreadPool = try .init(cpu_count, testing.allocator);
//     defer tp.deinit();
//     try tp.start();
//     defer tp.stop();

//     const Ctx = struct {
//         channel: Channel(usize),
//         senders_done: Atomic(usize) = .init(0),
//         receivers_done: Atomic(usize) = .init(0),
//         total_message_count: Atomic(usize) = .init(0),
//         wait_group: std.Thread.WaitGroup,

//         target_count: usize,

//         pub fn sender(ctx: *@This(), id: usize, messages_per_sender: usize) !void {
//             for (0..messages_per_sender) |i| {
//                 ctx.channel.send(id * messages_per_sender + i);
//             }
//             if (ctx.total_message_count.fetchAdd(
//                 messages_per_sender,
//                 .seq_cst,
//             ) + messages_per_sender == ctx.target_count) {
//                 ctx.channel.close();
//             }
//             _ = ctx.senders_done.fetchAdd(1, .seq_cst);
//             ctx.wait_group.finish();
//         }

//         pub fn receiver(ctx: *@This()) !void {
//             while (ctx.channel.receive()) |_| {}
//             _ = ctx.receivers_done.fetchAdd(1, .seq_cst);
//             ctx.wait_group.finish();
//         }
//     };

//     const receiver_count = 100;
//     const sender_count = 100;
//     const messages_per_sender = 10000;

//     var ctx: Ctx = .{
//         .channel = .{},
//         .target_count = sender_count * messages_per_sender,
//         .wait_group = .{},
//     };

//     ctx.wait_group.startMany(sender_count + receiver_count);

//     for (0..receiver_count) |_| {
//         try Fiber.go(
//             Ctx.receiver,
//             .{&ctx},
//             testing.allocator,
//             tp.executor(),
//         );
//     }

//     for (0..sender_count) |i| {
//         try Fiber.go(
//             Ctx.sender,
//             .{
//                 &ctx,
//                 i,
//                 messages_per_sender,
//             },
//             testing.allocator,
//             tp.executor(),
//         );
//     }

//     ctx.wait_group.wait();

//     try testing.expectEqual(sender_count, ctx.senders_done.load(.seq_cst));
//     try testing.expectEqual(receiver_count, ctx.receivers_done.load(.seq_cst));
// }
