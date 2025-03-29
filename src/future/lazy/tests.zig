const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const executors = @import("../../main.zig").executors;
const future = @import("../main.zig").lazy;

test "lazy future - submit - basic" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    var pool: executors.ThreadPools.Compute = try .init(1, allocator);
    defer pool.deinit();
    try pool.start();
    defer pool.stop();
    var compute = future.submit(
        pool.executor(),
        struct {
            pub fn run() usize {
                return 11;
            }
        }.run,
    );
    const result: anyerror!usize = future.get(&compute);
    try testing.expectEqual(11, result);
}
