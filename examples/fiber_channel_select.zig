const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("cozi");
const ThreadPool = cozi.executors.threadPools.Compute;
const Fiber = cozi.Fiber;
const Channel = cozi.Fiber.Channel;
const select = cozi.Fiber.select;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.detectLeaks()) {
            unreachable;
        }
    }

    var thread_pool = try ThreadPool.init(1, allocator);
    const executor = thread_pool.executor();
    defer thread_pool.deinit();
    try thread_pool.start();
    defer thread_pool.stop();

    const Ctx = struct {
        channel_usize: Channel(usize) = .{},
        channel_string: Channel([]const u8) = .{},
        wait_group: std.Thread.WaitGroup = .{},

        const Self = @This();

        pub fn sendString(ctx: *Self) void {
            ctx.channel_string.send("456");
            ctx.wait_group.finish();
        }

        pub fn receiver(ctx: *Self) void {
            switch (select(
                .{
                    .{ .receive, &ctx.channel_usize },
                    .{ .receive, &ctx.channel_string },
                },
            )) {
                .@"0" => |_| {
                    unreachable;
                },
                .@"1" => |optional_result_string| {
                    // null indicates that channel was closed
                    if (optional_result_string) |result_string| {
                        assert(std.mem.eql(u8, "456", result_string));
                    } else unreachable;
                },
            }
            ctx.wait_group.finish();
        }
    };

    var ctx: Ctx = .{};
    ctx.wait_group.startMany(2);

    try Fiber.go(
        Ctx.receiver,
        .{&ctx},
        allocator,
        executor,
    );

    try Fiber.go(
        Ctx.sendString,
        .{&ctx},
        allocator,
        executor,
    );

    // Synchronize Fibers running in a thread pool
    // with the launching (main) thread.
    ctx.wait_group.wait();
}
