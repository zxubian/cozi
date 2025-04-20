const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fault = @import("../../fault/root.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const WaitGroup = std.Thread.WaitGroup;

const Fiber = @import("../root.zig");
const Channel = Fiber.Channel;
const executors = @import("../../executors/root.zig");
const ThreadPool = executors.threadPools.Compute;
const ManualExecutor = executors.Manual;

test "Channel - Basic - Sender First" {
    var manual: ManualExecutor = .{};

    const Ctx = struct {
        channel: Channel(usize),
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This()) !void {
            ctx.channel.send(1);
            ctx.sender_done = true;
        }

        pub fn receiver(ctx: *@This()) !void {
            const value = ctx.channel.receive();
            try testing.expectEqual(1, value);
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{ .channel = .{} };

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.sender, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(ctx.receiver_done);
}

test "Channel - Basic - Receiver First" {
    var manual: ManualExecutor = .{};

    const Ctx = struct {
        channel: Channel(usize),
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This()) !void {
            ctx.channel.send(1);
            ctx.sender_done = true;
        }

        pub fn receiver(ctx: *@This()) !void {
            const value = ctx.channel.receive();
            try testing.expectEqual(1, value);
            ctx.receiver_done = true;
        }
    };

    var ctx: Ctx = .{ .channel = .{} };

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.sender, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(ctx.receiver_done);
}

test "Channel - Basic - Multiple Senders First" {
    var manual: ManualExecutor = .{};

    const Ctx = struct {
        channel: Channel(usize),
        last_received_value: usize = 0,
        senders_done: usize = 0,
        receivers_done: usize = 0,

        pub fn sender(ctx: *@This(), i: usize) !void {
            ctx.channel.send(i);
            ctx.senders_done += 1;
        }

        pub fn receiver(ctx: *@This()) !void {
            const value = ctx.channel.receive();
            try testing.expectEqual(ctx.last_received_value, value);
            ctx.last_received_value += 1;
            ctx.receivers_done += 1;
        }
    };

    var ctx: Ctx = .{ .channel = .{} };

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    const sender_count = 2;
    for (0..sender_count) |sender_idx| {
        try Fiber.go(Ctx.sender, .{ &ctx, sender_idx }, testing.allocator, manual.executor());
    }
    _ = manual.drain();

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(1, ctx.senders_done);
    try testing.expectEqual(1, ctx.receivers_done);

    try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(2, ctx.senders_done);
    try testing.expectEqual(2, ctx.receivers_done);
}

test "Channel - Basic - Multiple Receivers First" {
    var manual: ManualExecutor = .{};

    const Ctx = struct {
        channel: Channel(usize),
        last_received_value: usize = 0,
        senders_done: usize = 0,
        receivers_done: usize = 0,

        pub fn sender(ctx: *@This(), i: usize) !void {
            ctx.channel.send(i);
            ctx.senders_done += 1;
        }

        pub fn receiver(ctx: *@This()) !void {
            const value = ctx.channel.receive();
            try testing.expectEqual(ctx.last_received_value, value);
            ctx.last_received_value += 1;
            ctx.receivers_done += 1;
        }
    };

    var ctx: Ctx = .{ .channel = .{} };

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    const receiver_count = 2;
    for (0..receiver_count) |_| {
        try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
    }
    _ = manual.drain();

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    try Fiber.go(Ctx.sender, .{ &ctx, 0 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(1, ctx.senders_done);
    try testing.expectEqual(1, ctx.receivers_done);

    try Fiber.go(Ctx.sender, .{ &ctx, 1 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(2, ctx.senders_done);
    try testing.expectEqual(2, ctx.receivers_done);
}

test "Channel - Basic - multiple send" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel: Channel(usize),
        senders_done: usize = 0,
        receivers_done: usize = 0,

        pub fn sender(ctx: *@This(), count: usize) !void {
            for (0..count) |i| {
                ctx.channel.send(i);
            }
            ctx.senders_done += 1;
        }

        pub fn receiver(ctx: *@This(), count: usize) !void {
            for (0..count) |i| {
                const value = ctx.channel.receive();
                try testing.expectEqual(i, value);
            }
            ctx.receivers_done += 1;
        }
    };

    var ctx: Ctx = .{ .channel = .{} };

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    try Fiber.go(Ctx.receiver, .{ &ctx, 10 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    try Fiber.go(Ctx.sender, .{ &ctx, 10 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(1, ctx.senders_done);
    try testing.expectEqual(1, ctx.receivers_done);
}

test "Channel - Basic - close" {
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        channel: Channel(usize),
        senders_done: usize = 0,
        receivers_done: usize = 0,

        pub fn sender(ctx: *@This(), count: usize) !void {
            for (0..count) |i| {
                ctx.channel.send(i);
            }
            ctx.channel.close();
            ctx.senders_done += 1;
        }

        pub fn receiver(ctx: *@This(), count: usize) !void {
            var i: usize = 0;
            while (ctx.channel.receive()) |value| : (i += 1) {
                try testing.expectEqual(i, value);
            }
            try testing.expectEqual(count, i);
            ctx.receivers_done += 1;
        }
    };

    var ctx: Ctx = .{ .channel = .{} };

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    try Fiber.go(Ctx.receiver, .{ &ctx, 10 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(0, ctx.senders_done);
    try testing.expectEqual(0, ctx.receivers_done);

    try Fiber.go(Ctx.sender, .{ &ctx, 10 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(1, ctx.senders_done);
    try testing.expectEqual(1, ctx.receivers_done);
}

test "Channel - Stress - SPSC" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp: ThreadPool = try .init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Ctx = struct {
        channel: Channel(usize),
        senders_done: Atomic(usize) = .init(0),
        receivers_done: Atomic(usize) = .init(0),
        total_message_count: Atomic(usize) = .init(0),
        wait_group: std.Thread.WaitGroup,

        target_count: usize,

        pub fn sender(ctx: *@This(), id: usize, messages_per_sender: usize) !void {
            for (0..messages_per_sender) |i| {
                ctx.channel.send(id * messages_per_sender + i);
            }
            if (ctx.total_message_count.fetchAdd(
                messages_per_sender,
                .seq_cst,
            ) + messages_per_sender == ctx.target_count) {
                ctx.channel.close();
            }
            _ = ctx.senders_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }

        pub fn receiver(ctx: *@This()) !void {
            while (ctx.channel.receive()) |_| {}
            _ = ctx.receivers_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }
    };

    const receiver_count = 1;
    const sender_count = 1;
    const messages_per_sender = 10000;

    var ctx: Ctx = .{
        .channel = .{},
        .target_count = sender_count * messages_per_sender,
        .wait_group = .{},
    };

    ctx.wait_group.startMany(sender_count + receiver_count);

    for (0..receiver_count) |_| {
        try Fiber.go(
            Ctx.receiver,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }

    for (0..sender_count) |i| {
        try Fiber.go(
            Ctx.sender,
            .{
                &ctx,
                i,
                messages_per_sender,
            },
            testing.allocator,
            tp.executor(),
        );
    }

    ctx.wait_group.wait();

    try testing.expectEqual(sender_count, ctx.senders_done.load(.seq_cst));
    try testing.expectEqual(receiver_count, ctx.receivers_done.load(.seq_cst));
}

test "Channel - Stress - MPSC" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp: ThreadPool = try .init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Ctx = struct {
        channel: Channel(usize),
        senders_done: Atomic(usize) = .init(0),
        receivers_done: Atomic(usize) = .init(0),
        total_message_count: Atomic(usize) = .init(0),
        wait_group: std.Thread.WaitGroup,

        target_count: usize,

        pub fn sender(ctx: *@This(), id: usize, messages_per_sender: usize) !void {
            for (0..messages_per_sender) |i| {
                ctx.channel.send(id * messages_per_sender + i);
            }
            if (ctx.total_message_count.fetchAdd(
                messages_per_sender,
                .seq_cst,
            ) + messages_per_sender == ctx.target_count) {
                ctx.channel.close();
            }
            _ = ctx.senders_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }

        pub fn receiver(ctx: *@This()) !void {
            while (ctx.channel.receive()) |_| {}
            _ = ctx.receivers_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }
    };

    const receiver_count = 1;
    const sender_count = 100;
    const messages_per_sender = 10000;

    var ctx: Ctx = .{
        .channel = .{},
        .target_count = sender_count * messages_per_sender,
        .wait_group = .{},
    };

    ctx.wait_group.startMany(sender_count + receiver_count);

    for (0..receiver_count) |_| {
        try Fiber.go(
            Ctx.receiver,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }

    for (0..sender_count) |i| {
        try Fiber.go(
            Ctx.sender,
            .{
                &ctx,
                i,
                messages_per_sender,
            },
            testing.allocator,
            tp.executor(),
        );
    }

    ctx.wait_group.wait();

    try testing.expectEqual(sender_count, ctx.senders_done.load(.seq_cst));
    try testing.expectEqual(receiver_count, ctx.receivers_done.load(.seq_cst));
}

test "Channel - Stress - SPMC" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp: ThreadPool = try .init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Ctx = struct {
        channel: Channel(usize),
        senders_done: Atomic(usize) = .init(0),
        receivers_done: Atomic(usize) = .init(0),
        total_message_count: Atomic(usize) = .init(0),
        wait_group: std.Thread.WaitGroup,

        target_count: usize,

        pub fn sender(ctx: *@This(), id: usize, messages_per_sender: usize) !void {
            for (0..messages_per_sender) |i| {
                ctx.channel.send(id * messages_per_sender + i);
            }
            if (ctx.total_message_count.fetchAdd(
                messages_per_sender,
                .seq_cst,
            ) + messages_per_sender == ctx.target_count) {
                ctx.channel.close();
            }
            _ = ctx.senders_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }

        pub fn receiver(ctx: *@This()) !void {
            while (ctx.channel.receive()) |_| {}
            _ = ctx.receivers_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }
    };

    const receiver_count = 100;
    const sender_count = 1;
    const messages_per_sender = 10000;

    var ctx: Ctx = .{
        .channel = .{},
        .target_count = sender_count * messages_per_sender,
        .wait_group = .{},
    };

    ctx.wait_group.startMany(sender_count + receiver_count);

    for (0..receiver_count) |_| {
        try Fiber.go(
            Ctx.receiver,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }

    for (0..sender_count) |i| {
        try Fiber.go(
            Ctx.sender,
            .{
                &ctx,
                i,
                messages_per_sender,
            },
            testing.allocator,
            tp.executor(),
        );
    }

    ctx.wait_group.wait();

    try testing.expectEqual(sender_count, ctx.senders_done.load(.seq_cst));
    try testing.expectEqual(receiver_count, ctx.receivers_done.load(.seq_cst));
}

test "Channel - Stress - MPMC" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp: ThreadPool = try .init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Ctx = struct {
        channel: Channel(usize),
        senders_done: Atomic(usize) = .init(0),
        receivers_done: Atomic(usize) = .init(0),
        total_message_count: Atomic(usize) = .init(0),
        wait_group: std.Thread.WaitGroup,

        target_count: usize,

        pub fn sender(ctx: *@This(), id: usize, messages_per_sender: usize) !void {
            for (0..messages_per_sender) |i| {
                ctx.channel.send(id * messages_per_sender + i);
            }
            if (ctx.total_message_count.fetchAdd(
                messages_per_sender,
                .seq_cst,
            ) + messages_per_sender == ctx.target_count) {
                ctx.channel.close();
            }
            _ = ctx.senders_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }

        pub fn receiver(ctx: *@This()) !void {
            while (ctx.channel.receive()) |_| {}
            _ = ctx.receivers_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }
    };

    const receiver_count = 100;
    const sender_count = 100;
    const messages_per_sender = 10000;

    var ctx: Ctx = .{
        .channel = .{},
        .target_count = sender_count * messages_per_sender,
        .wait_group = .{},
    };

    ctx.wait_group.startMany(sender_count + receiver_count);

    for (0..receiver_count) |_| {
        try Fiber.go(
            Ctx.receiver,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }

    for (0..sender_count) |i| {
        try Fiber.go(
            Ctx.sender,
            .{
                &ctx,
                i,
                messages_per_sender,
            },
            testing.allocator,
            tp.executor(),
        );
    }

    ctx.wait_group.wait();

    try testing.expectEqual(sender_count, ctx.senders_done.load(.seq_cst));
    try testing.expectEqual(receiver_count, ctx.receivers_done.load(.seq_cst));
}
