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
    const result: usize = try future.get(&compute);
    try testing.expectEqual(11, result);
}

test "lazy future - just - basic" {
    var just = future.just();
    try future.get(&just);
}

test "lazy future - value - basic" {
    var value = future.value(@as(usize, 44));
    const result = try future.get(&value);
    try testing.expectEqual(44, result);
}
