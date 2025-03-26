const std = @import("std");
const ZigAsync = @import("zig-async");
const ThreadPool = ZigAsync.executors.ThreadPools.Compute;
const Fiber = ZigAsync.Fiber;
const Channel = Fiber.Channel;
const Atomic = ZigAsync.fault.stdlike.atomic;
const select = Fiber.select;
const assert = std.debug.assert;

pub const std_options = std.Options{
    .log_level = .err,
};

const log = std.log.scoped(.example);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    defer {
        if (gpa.detectLeaks()) {
            unreachable;
        }
    }

    // const cpu_count = try std.Thread.getCpuCount();
    const cpu_count = 2;
    var tp: ThreadPool = try .init(cpu_count, allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();
    const executor = tp.executor();
    // _ = tp.executor();

    // var manual = ZigAsync.executors.Manual{};
    // const executor = manual.executor();

    const messages_per_sender = 4;
    const selector_count = 2;
    const sender_count = 2;
    const total_message_count = messages_per_sender * sender_count;
    const messages_per_channel = total_message_count / 2;

    const Ctx = struct {
        channels: [2]Channel(usize) = [_]Channel(usize){.{}} ** 2,
        wait_group: std.Thread.WaitGroup = .{},
        sent_message_count: [2]Atomic.Value(usize) = [_]Atomic.Value(usize){.init(0)} ** 2,
        received_message_count: Atomic.Value(usize) = .init(0),
        senders_done: Atomic.Value(usize) = .init(0),
        selectors_done: Atomic.Value(usize) = .init(0),

        pub fn sender(ctx: *@This(), id: usize) !void {
            const channel: *Channel(usize) = &ctx.channels[id % 2];
            for (0..messages_per_sender) |i| {
                log.debug("sender #{} about to send message #{}", .{ id, i });
                channel.send(id * messages_per_sender + i);
                log.debug("sender #{} sent message #{}", .{ id, i });
            }
            log.debug("sender #{} sent all of its messages", .{id});
            if (ctx.sent_message_count[id % 2].fetchAdd(
                messages_per_sender,
                .seq_cst,
            ) + messages_per_sender == messages_per_channel) {
                channel.tryClose() catch {};
            }
            _ = ctx.senders_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }

        pub fn selector(ctx: *@This(), id: usize) !void {
            while (ctx.received_message_count.load(.seq_cst) < total_message_count) {
                const result = switch (select(.{
                    .{ .receive, &ctx.channels[id % 2] },
                    .{ .receive, &ctx.channels[(id + 1) % 2] },
                })) {
                    inline else => |value| value,
                };
                if (result == null) {
                    if (ctx.channels[0].closed.load(.seq_cst) and ctx.channels[1].closed.load(.seq_cst)) {
                        break;
                    }
                } else {
                    _ = ctx.received_message_count.fetchAdd(1, .seq_cst);
                }
                Fiber.yield();
            }
            _ = ctx.selectors_done.fetchAdd(1, .seq_cst);
            ctx.wait_group.finish();
        }
    };

    var ctx: Ctx = .{};

    ctx.wait_group.startMany(sender_count + selector_count);

    for (0..selector_count) |i| {
        try Fiber.goWithNameFmt(
            Ctx.selector,
            .{ &ctx, i },
            allocator,
            executor,
            "Selector#{}",
            .{i},
        );
    }

    for (0..sender_count) |i| {
        try Fiber.goWithNameFmt(
            Ctx.sender,
            .{
                &ctx,
                i,
            },
            allocator,
            executor,
            "Sender#{}",
            .{i},
        );
    }

    ctx.wait_group.wait();

    assert(sender_count == ctx.senders_done.load(.seq_cst));
    assert(selector_count == ctx.selectors_done.load(.seq_cst));
}
