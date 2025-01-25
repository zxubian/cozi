const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fault = @import("../../../fault/main.zig");
const stdlike = fault.stdlike;

const WaitGroup = std.Thread.WaitGroup;

const Fiber = @import("../../main.zig");
const Channel = Fiber.Channel;
const Executors = @import("../../../executors/main.zig");
const ThreadPool = Executors.ThreadPools.Compute;
const ManualExecutor = Executors.Manual;

test "BufferedChannel - Ping Pong" {
    var manual: ManualExecutor = .{};

    const buffer_size = 4;
    const message_count_per_loop = 3;
    const loop_count = 2;

    const Ctx = struct {
        channel: Channel(usize).Buffered.Managed,
        send_counter: usize = 0,
        recv_counter: usize = 0,
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This()) !void {
            try testing.expect(!ctx.sender_done);
            try testing.expect(!ctx.receiver_done);
            for (0..message_count_per_loop) |_| {
                ctx.channel.send(ctx.send_counter);
                ctx.send_counter += 1;
            }
            ctx.sender_done = true;
        }

        pub fn receiver(ctx: *@This()) !void {
            try testing.expect(ctx.sender_done);
            try testing.expect(!ctx.receiver_done);
            for (0..message_count_per_loop) |_| {
                const value = ctx.channel.receive();
                try testing.expectEqual(ctx.recv_counter, value);
                ctx.recv_counter += 1;
            }
            ctx.receiver_done = true;
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(buffer_size, testing.allocator);
    defer channel.deinit();

    var ctx: Ctx = .{ .channel = channel };

    for (0..loop_count) |_| {
        ctx.sender_done = false;
        ctx.receiver_done = false;
        try testing.expect(!ctx.sender_done);
        try testing.expect(!ctx.receiver_done);

        try Fiber.go(Ctx.sender, .{&ctx}, testing.allocator, manual.executor());
        _ = manual.drain();

        try testing.expect(ctx.sender_done);
        try testing.expect(!ctx.receiver_done);

        try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
        _ = manual.drain();

        try testing.expect(ctx.sender_done);
        try testing.expect(ctx.receiver_done);
    }
    _ = manual.drain();
}

test "BufferedChannel - Sequential" {
    var manual: ManualExecutor = .{};

    const buffer_size = 4;
    const message_count_per_loop = 3;
    const loop_count = 100;

    const Ctx = struct {
        channel: Channel(usize).Buffered.Managed,
        send_counter: usize = 0,
        recv_counter: usize = 0,
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This()) !void {
            try testing.expect(!ctx.sender_done);
            try testing.expect(!ctx.receiver_done);
            for (0..message_count_per_loop) |_| {
                ctx.channel.send(ctx.send_counter);
                ctx.send_counter += 1;
            }
            ctx.sender_done = true;
        }

        pub fn receiver(ctx: *@This()) !void {
            try testing.expect(ctx.sender_done);
            try testing.expect(!ctx.receiver_done);
            for (0..message_count_per_loop) |_| {
                const value = ctx.channel.receive();
                try testing.expectEqual(ctx.recv_counter, value);
                ctx.recv_counter += 1;
            }
            ctx.receiver_done = true;
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(buffer_size, testing.allocator);
    defer channel.deinit();

    var ctx: Ctx = .{ .channel = channel };

    for (0..loop_count) |_| {
        ctx.sender_done = false;
        ctx.receiver_done = false;
        try testing.expect(!ctx.sender_done);
        try testing.expect(!ctx.receiver_done);

        try Fiber.go(Ctx.sender, .{&ctx}, testing.allocator, manual.executor());
        _ = manual.drain();

        try testing.expect(ctx.sender_done);
        try testing.expect(!ctx.receiver_done);

        try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
        _ = manual.drain();

        try testing.expect(ctx.sender_done);
        try testing.expect(ctx.receiver_done);
    }
    _ = manual.drain();
}

test "BufferedChannel - Close - return null" {
    var manual: ManualExecutor = .{};

    const buffer_size = 4;
    const message_count = 3;

    const Ctx = struct {
        channel: Channel(usize).Buffered.Managed,
        send_counter: usize = 0,
        recv_counter: usize = 0,
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This()) !void {
            try testing.expect(!ctx.sender_done);
            try testing.expect(!ctx.receiver_done);
            for (0..message_count) |_| {
                ctx.channel.send(ctx.send_counter);
                ctx.send_counter += 1;
            }
            ctx.channel.close();
            ctx.sender_done = true;
        }

        pub fn receiver(ctx: *@This()) !void {
            try testing.expect(ctx.sender_done);
            try testing.expect(!ctx.receiver_done);
            while (ctx.channel.receive()) |value| : (ctx.recv_counter += 1) {
                try testing.expectEqual(ctx.recv_counter, value);
            }
            ctx.receiver_done = true;
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(buffer_size, testing.allocator);
    defer channel.deinit();

    var ctx: Ctx = .{ .channel = channel };

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.sender, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(ctx.receiver_done);
}

test "BufferedChannel - park sender when buffer is full" {
    var manual: ManualExecutor = .{};

    const buffer_size = 4;
    const message_count = 5;

    const Ctx = struct {
        channel: Channel(usize).Buffered.Managed,
        send_counter: usize = 0,
        recv_counter: usize = 0,
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This()) !void {
            for (0..message_count) |_| {
                ctx.channel.send(ctx.send_counter);
                ctx.send_counter += 1;
            }
            ctx.sender_done = true;
        }

        pub fn receiver(ctx: *@This(), count: usize) !void {
            for (0..count) |_| {
                const value = ctx.channel.receive();
                try testing.expectEqual(ctx.recv_counter, value.?);
                ctx.recv_counter += 1;
            }
            if (ctx.recv_counter == message_count) {
                ctx.receiver_done = true;
            }
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(
        buffer_size,
        testing.allocator,
    );
    defer channel.deinit();

    var ctx: Ctx = .{ .channel = channel };

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.sender, .{&ctx}, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(!ctx.sender_done);
    try testing.expectEqual(4, ctx.send_counter);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.receiver, .{ &ctx, 1 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(!ctx.receiver_done);
    try testing.expectEqual(1, ctx.recv_counter);

    try Fiber.go(Ctx.receiver, .{ &ctx, 4 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expect(ctx.sender_done);
    try testing.expect(ctx.receiver_done);
    try testing.expectEqual(5, ctx.recv_counter);
    try testing.expectEqual(5, ctx.recv_counter);
}

test "BufferedChannel - park receiver when buffer is empty" {
    var manual: ManualExecutor = .{};

    const buffer_size = 4;
    const message_count = 4;

    const Ctx = struct {
        channel: Channel(usize).Buffered.Managed,
        send_counter: usize = 0,
        recv_counter: usize = 0,
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This(), count: usize) !void {
            for (0..count) |_| {
                ctx.channel.send(ctx.send_counter);
                ctx.send_counter += 1;
            }
            if (ctx.send_counter == message_count) {
                ctx.sender_done = true;
            }
        }

        pub fn receiver(ctx: *@This(), count: usize) !void {
            for (0..count) |_| {
                const value = ctx.channel.receive();
                try testing.expectEqual(ctx.recv_counter, value.?);
                ctx.recv_counter += 1;
            }
            if (ctx.recv_counter == message_count) {
                ctx.receiver_done = true;
            }
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(
        buffer_size,
        testing.allocator,
    );
    defer channel.deinit();

    var ctx: Ctx = .{ .channel = channel };

    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.receiver, .{ &ctx, 4 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(0, ctx.recv_counter);
    try testing.expectEqual(0, ctx.send_counter);
    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.sender, .{ &ctx, 1 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(1, ctx.recv_counter);
    try testing.expectEqual(1, ctx.send_counter);
    try testing.expect(!ctx.sender_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(Ctx.sender, .{ &ctx, 3 }, testing.allocator, manual.executor());
    _ = manual.drain();

    try testing.expectEqual(4, ctx.recv_counter);
    try testing.expectEqual(4, ctx.send_counter);
    try testing.expect(ctx.sender_done);
    try testing.expect(ctx.receiver_done);
}

test "BufferedChannel - close wakes up suspended receiver" {
    var manual: ManualExecutor = .{};

    const buffer_size = 1;

    const Ctx = struct {
        channel: Channel(usize).Buffered.Managed,
        sender_done: bool = false,
        receiver_done: bool = false,

        pub fn sender(ctx: *@This()) !void {
            ctx.channel.close();
            ctx.sender_done = true;
        }

        pub fn receiver(ctx: *@This()) !void {
            while (ctx.channel.receive()) |_| {
                unreachable;
            }
            ctx.receiver_done = true;
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(
        buffer_size,
        testing.allocator,
    );
    defer channel.deinit();

    var ctx: Ctx = .{ .channel = channel };

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

test "BufferedChannel - Fiber - Buffered Channel - Basic - Thread Pool" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(4, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const buffer_size = 4;
    const message_count = 128;

    const Ctx = struct {
        wait_group: WaitGroup = .{},
        channel: Channel(usize).Buffered.Managed,

        pub fn sender(ctx: *@This()) void {
            for (0..message_count) |i| {
                ctx.channel.send(i);
            }
            ctx.channel.close();
            ctx.wait_group.finish();
        }

        pub fn receiver(ctx: *@This()) !void {
            var i: usize = 0;
            while (ctx.channel.receive()) |value| : (i += 1) {
                try testing.expectEqual(i, value);
            }
            ctx.wait_group.finish();
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(buffer_size, testing.allocator);
    defer channel.deinit();

    var ctx: Ctx = .{
        .channel = channel,
    };

    ctx.wait_group.startMany(2);

    try Fiber.go(Ctx.sender, .{&ctx}, testing.allocator, tp.executor());
    try Fiber.go(Ctx.receiver, .{&ctx}, testing.allocator, tp.executor());

    ctx.wait_group.wait();
}

test "BufferedChannel - Fiber - Buffered Channel - Stress SPMC" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();

    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const buffer_size = 1000;
    const message_count = 1000000;
    const producer_count = 1;
    const consumer_count = 100;
    const messages_per_consumer = message_count / consumer_count;
    const messages_per_producer = message_count / producer_count;

    const Ctx = struct {
        wait_group: WaitGroup = .{},
        channel: Channel(usize).Buffered.Managed,
        producer_counter: stdlike.atomic.Value(usize) = .init(0),

        pub fn producer(ctx: *@This(), producer_idx: usize) void {
            for (0..messages_per_producer) |i| {
                ctx.channel.send(producer_idx * messages_per_producer + i);
                if (ctx.producer_counter.fetchAdd(1, .monotonic) + 1 ==
                    message_count)
                {
                    ctx.channel.close();
                }
            }
            ctx.wait_group.finish();
        }

        pub fn consumer(ctx: *@This(), _: usize) !void {
            var i: usize = 0;
            while (i < messages_per_consumer) : (i += 1) {
                if (ctx.channel.receive() == null) {
                    break;
                }
            }
            try testing.expectEqual(i, messages_per_consumer);
            ctx.wait_group.finish();
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(
        buffer_size,
        testing.allocator,
    );
    defer channel.deinit();

    var ctx: Ctx = .{
        .channel = channel,
    };

    var name_buffer: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES]u8 = undefined;

    for (0..producer_count) |i| {
        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.producer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{ .fiber = .{
                .name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "Producer #{}",
                    .{i},
                ),
            } },
        );
    }

    for (0..consumer_count) |i| {
        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.consumer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{ .fiber = .{
                .name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "Consumer #{}",
                    .{i},
                ),
            } },
        );
    }

    ctx.wait_group.wait();
    try testing.expectEqual(ctx.producer_counter.load(.monotonic), message_count);
}

test "BufferedChannel - Fiber - Buffered Channel - Stress MPSC" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();

    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const buffer_size = 1000;
    const message_count = 1000000;
    const producer_count = 100;
    const consumer_count = 1;
    const messages_per_consumer = message_count / consumer_count;
    const messages_per_producer = message_count / producer_count;

    const Ctx = struct {
        wait_group: WaitGroup = .{},
        channel: Channel(usize).Buffered.Managed,
        producer_counter: stdlike.atomic.Value(usize) = .init(0),

        pub fn producer(ctx: *@This(), producer_idx: usize) void {
            for (0..messages_per_producer) |i| {
                ctx.channel.send(producer_idx * messages_per_producer + i);
                if (ctx.producer_counter.fetchAdd(1, .monotonic) + 1 ==
                    message_count)
                {
                    ctx.channel.close();
                }
            }
            ctx.wait_group.finish();
        }

        pub fn consumer(ctx: *@This(), _: usize) !void {
            var i: usize = 0;
            while (i < messages_per_consumer) : (i += 1) {
                if (ctx.channel.receive() == null) {
                    break;
                }
            }
            try testing.expectEqual(i, messages_per_consumer);
            ctx.wait_group.finish();
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(
        buffer_size,
        testing.allocator,
    );
    defer channel.deinit();

    var ctx: Ctx = .{
        .channel = channel,
    };

    var name_buffer: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES]u8 = undefined;

    for (0..producer_count) |i| {
        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.producer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{ .fiber = .{
                .name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "Producer #{}",
                    .{i},
                ),
            } },
        );
    }

    for (0..consumer_count) |i| {
        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.consumer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{ .fiber = .{
                .name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "Consumer #{}",
                    .{i},
                ),
            } },
        );
    }

    ctx.wait_group.wait();
    try testing.expectEqual(ctx.producer_counter.load(.monotonic), message_count);
}

test "BufferedChannel - Fiber - Buffered Channel - Stress MPMC" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();

    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const buffer_size = 1000;
    const message_count = 1000000;
    const producer_count = 100;
    const consumer_count = 100;
    const messages_per_consumer = message_count / consumer_count;
    const messages_per_producer = message_count / producer_count;

    const Ctx = struct {
        wait_group: WaitGroup = .{},
        channel: Channel(usize).Buffered.Managed,
        producer_counter: stdlike.atomic.Value(usize) = .init(0),

        pub fn producer(ctx: *@This(), producer_idx: usize) void {
            for (0..messages_per_producer) |i| {
                ctx.channel.send(producer_idx * messages_per_producer + i);
                if (ctx.producer_counter.fetchAdd(1, .monotonic) + 1 ==
                    message_count)
                {
                    ctx.channel.close();
                }
            }
            ctx.wait_group.finish();
        }

        pub fn consumer(ctx: *@This(), _: usize) !void {
            var i: usize = 0;
            while (i < messages_per_consumer) : (i += 1) {
                if (ctx.channel.receive() == null) {
                    break;
                }
            }
            try testing.expectEqual(i, messages_per_consumer);
            ctx.wait_group.finish();
        }
    };

    var channel = try Channel(usize).Buffered.Managed.init(
        buffer_size,
        testing.allocator,
    );
    defer channel.deinit();

    var ctx: Ctx = .{
        .channel = channel,
    };

    var name_buffer: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES]u8 = undefined;

    for (0..producer_count) |i| {
        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.producer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{ .fiber = .{
                .name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "Producer #{}",
                    .{i},
                ),
            } },
        );
    }

    for (0..consumer_count) |i| {
        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.consumer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{ .fiber = .{
                .name = try std.fmt.bufPrintZ(
                    &name_buffer,
                    "Consumer #{}",
                    .{i},
                ),
            } },
        );
    }

    ctx.wait_group.wait();
    try testing.expectEqual(ctx.producer_counter.load(.monotonic), message_count);
}
