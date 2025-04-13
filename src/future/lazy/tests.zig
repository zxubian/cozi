const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const executors = @import("../../main.zig").executors;
const future = @import("../main.zig").lazy;
const ThreadPool = executors.threadPools.Compute;
const InlineExecutor = executors.@"inline";

test "lazy future - just - basic" {
    const just = future.just();
    future.get(just);
}

test "lazy future - const value - basic" {
    const value = future.constValue(@as(usize, 44));
    const result = future.get(value);
    try testing.expectEqual(44, result);
}

test "lazy future - value - basic" {
    const value = future.value(@as(usize, 44));
    const result = future.get(value);
    try testing.expectEqual(44, result);
}

test "lazy future - pipeline - basic" {
    const value = future.value(@as(usize, 44));
    const via = future.via(InlineExecutor).pipe(value);
    const map = future.map(struct {
        pub fn run(
            _: ?*anyopaque,
            in: usize,
        ) usize {
            return in + 1;
        }
    }.run, null).pipe(via);
    const result = future.get(map);
    try testing.expectEqual(45, result);
}

test "lazy future - pipeline - multiple" {
    const value = future.value(@as(usize, 0));
    const via = future.via(InlineExecutor).pipe(value);
    const map = future.map(struct {
        pub fn run(
            _: ?*anyopaque,
            in: usize,
        ) usize {
            return in + 1;
        }
    }.run, null).pipe(via);
    const map_2 = future.map(struct {
        pub fn run(
            _: ?*anyopaque,
            in: usize,
        ) usize {
            return in + 2;
        }
    }.run, null).pipe(map);
    const result = future.get(map_2);
    try testing.expectEqual(3, result);
}

test "lazy future map - with side effects" {
    const just = future.just();
    const via = future.via(InlineExecutor).pipe(just);
    var done: bool = false;
    const map = future.map(struct {
        pub fn run(
            ctx: ?*anyopaque,
        ) void {
            const done_: *bool = @alignCast(@ptrCast(ctx));
            done_.* = true;
        }
    }.run, @alignCast(@ptrCast(&done))).pipe(via);
    future.get(map);
    try testing.expect(done);
}

test "lazy future - pipeline - syntax" {
    const pipeline = future.pipeline(
        .{
            future.value(@as(u32, 123)),
            future.via(InlineExecutor),
            future.map(struct {
                pub fn run(
                    _: ?*anyopaque,
                    in: u32,
                ) u32 {
                    return in + 1;
                }
            }.run, null),
        },
    );
    const result = future.get(pipeline);
    try testing.expectEqual(124, result);
}

test "lazy future - submit - basic" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    var pool: ThreadPool = try .init(1, allocator);
    defer pool.deinit();
    try pool.start();
    defer pool.stop();
    const compute = future.submit(
        pool.executor(),
        struct {
            pub fn run(_: ?*anyopaque) usize {
                return 11;
            }
        }.run,
        null,
    );
    const result: usize = future.get(compute);
    try testing.expectEqual(11, result);
}

test "lazy future - submit - timer" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    var pool: ThreadPool = try .init(1, allocator);
    defer pool.deinit();
    try pool.start();
    defer pool.stop();
    const compute = future.submit(
        pool.executor(),
        struct {
            pub fn run(_: ?*anyopaque) usize {
                std.Thread.sleep(std.time.ns_per_s);
                return 12;
            }
        }.run,
        null,
    );
    var timer: std.time.Timer = try .start();
    defer timer.reset();
    const result: usize = future.get(compute);
    const now = timer.read();
    try testing.expect(try std.math.divCeil(u64, now, std.time.ns_per_s) > 1);
    try testing.expectEqual(12, result);
}

test "lazy future - pipeline - fallible" {
    const pipeline = future.pipeline(
        .{
            future.value(@as(u32, 123)),
            future.map(struct {
                pub fn run(
                    _: ?*anyopaque,
                    in: u32,
                ) !u32 {
                    return in + 1;
                }
            }.run, null),
        },
    );
    const result = try future.get(pipeline);
    try testing.expectEqual(124, result);
}

test "lazy future - MapOk" {
    const pipeline = future.pipeline(
        .{
            future.value(@as(anyerror!u32, 123)),
            future.mapOk(struct {
                pub fn run(
                    _: ?*anyopaque,
                    in: u32,
                ) u32 {
                    return in + 1;
                }
            }.run, null),
        },
    );
    const result = future.get(pipeline);
    try testing.expectEqual(124, result);
}

test "lazy future - MapOk - not called on error" {
    const IoError = error{
        file_not_found,
    };
    const pipeline = future.pipeline(
        .{
            future.value(@as(IoError!u32, IoError.file_not_found)),
            future.mapOk(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: u32,
                ) u32 {
                    unreachable;
                }
            }.run, null),
        },
    );
    const result = future.get(pipeline);
    try testing.expectError(IoError.file_not_found, result);
}

test "lazy future - MapOk - return error" {
    const IoError = error{
        file_not_found,
    };
    const MapError = error{
        some_other_error,
    };
    const ThirdErrorType = error{
        abcd,
    };
    _ = ThirdErrorType;
    const pipeline = future.pipeline(
        .{
            future.value(@as(IoError!u32, 123)),
            future.mapOk(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: u32,
                ) MapError!u32 {
                    return MapError.some_other_error;
                }
            }.run, null),
        },
    );
    _ = future.get(pipeline) catch |err| switch (err) {
        IoError.file_not_found => unreachable,
        MapError.some_other_error => {},
        // uncommenting this will cause a compile error
        // ThirdErrorType.abcd => {},
    };
}

test "lazy future - andThen" {
    const IoError = error{
        file_not_found,
    };
    const pipeline = future.pipeline(
        .{
            future.constValue(@as(IoError!u32, 123)),
            future.andThen(struct {
                pub fn run(
                    _: ?*anyopaque,
                    input: u32,
                ) future.Value(IoError!u32) {
                    return future.value(@as(IoError!u32, input + 1));
                }
            }.run, null),
        },
    );
    const result = future.get(pipeline);
    try testing.expectEqual(124, result);
}

test "lazy future - andThen - return error" {
    const IoError = error{
        file_not_found,
    };
    const pipeline = future.pipeline(
        .{
            future.constValue(@as(IoError!u32, IoError.file_not_found)),
            future.andThen(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: u32,
                ) future.Value(IoError!u32) {
                    unreachable;
                }
            }.run, null),
        },
    );
    const result = future.get(pipeline);
    try testing.expectError(IoError.file_not_found, result);
}

test "lazy future - orElse" {
    const IoError = error{
        file_not_found,
    };
    const pipeline = future.pipeline(
        .{
            future.constValue(@as(IoError!u32, IoError.file_not_found)),
            future.orElse(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: IoError,
                ) future.Value(u32) {
                    return future.value(@as(u32, 123));
                }
            }.run, null),
        },
    );
    const result = future.get(pipeline);
    try testing.expectEqual(123, result);
}

test "lazy future - orElse - return value" {
    const IoError = error{
        file_not_found,
    };
    const pipeline = future.pipeline(
        .{
            future.constValue(@as(IoError!u32, 123)),
            future.orElse(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: IoError,
                ) future.Value(u32) {
                    unreachable;
                }
            }.run, null),
        },
    );
    const result = future.get(pipeline);
    try testing.expectEqual(123, result);
}

test "lazy future - pipeline - combinators" {
    const IoError = error{
        file_not_found,
    };
    const pipeline = future.pipeline(
        .{
            future.just(),
            future.map(struct {
                pub fn run(
                    _: ?*anyopaque,
                ) IoError!u32 {
                    return 3;
                }
            }.run, null),
            future.orElse(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: IoError,
                ) future.Value(u32) {
                    unreachable;
                }
            }.run, null),
            future.andThen(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: u32,
                ) future.Value(IoError!u32) {
                    return future.value(@as(
                        IoError!u32,
                        IoError.file_not_found,
                    ));
                }
            }.run, null),
            future.andThen(struct {
                pub fn run(
                    _: ?*anyopaque,
                    _: u32,
                ) future.Value(IoError!u32) {
                    unreachable;
                }
            }.run, null),
            future.orElse(struct {
                pub fn run(
                    _: ?*anyopaque,
                    err: IoError,
                ) future.Value(IoError!u32) {
                    assert(err == IoError.file_not_found);
                    return future.value(@as(IoError!u32, 3));
                }
            }.run, null),
            future.mapOk(struct {
                pub fn run(
                    _: ?*anyopaque,
                    in: u32,
                ) u32 {
                    return in + 1;
                }
            }.run, null),
        },
    );
    const result = try future.get(pipeline);
    try testing.expectEqual(4, result);
}
