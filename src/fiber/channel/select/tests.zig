const std = @import("std");
const log = std.log.scoped(.fiber_channel);
const testing = std.testing;

const Fiber = @import("../../main.zig");
const select = Fiber.select;

const Executors = @import("../../../executors/main.zig");
const ManualExecutor = Executors.Manual;

test "Select - Basic" {
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
                const result = select(
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

    try testing.expect(!ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(!ctx.receiver_done);

    try Fiber.go(
        Ctx.senderA,
        .{&ctx},
        testing.allocator,
        manual.executor(),
    );

    try testing.expect(ctx.sender_a_done);
    try testing.expect(ctx.sender_b_done);
    try testing.expect(ctx.receiver_done);
}
