const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const executors = @import("../../root.zig").executors;
const future = @import("../root.zig").lazy;
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

test "lazy future - flatten" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    var tp: ThreadPool = try .init(1, allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Ctx = struct {
        executor: executors.Executor,
        const Self = @This();
        pub fn run(ctx: ?*anyopaque) future.Submit(InnerCtx.inner_run) {
            const self: *Self = @alignCast(@ptrCast(ctx));
            return future.submit(self.executor, InnerCtx.inner_run, null);
        }
        const InnerCtx = struct {
            pub fn inner_run(_: ?*anyopaque) usize {
                return 7;
            }
        };
    };

    var ctx: Ctx = .{ .executor = tp.executor() };
    const nested = future.submit(
        tp.executor(),
        Ctx.run,
        &ctx,
    );
    const flattened = future.pipeline(.{
        nested,
        future.flatten(),
    });
    const result = future.get(flattened);
    try testing.expectEqual(7, result);
}

test "lazy future - contract - noalloc" {
    var shared_state: future.Contract(u32).SharedState = .{};
    const future_, const promise_ = future.contractNoAlloc(u32, &shared_state);
    promise_.resolve(3);
    const result = future.get(future_);
    try testing.expectEqual(3, result);
}

test "lazy future - contract - thread pool" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    var tp: ThreadPool = try .init(1, allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const future_, const promise_ = try future.contract(usize, std.testing.allocator);
    const transform = future.pipeline(.{
        future_,
        future.map(
            struct {
                pub fn run(
                    _: ?*anyopaque,
                    value: usize,
                ) usize {
                    return value * 3;
                }
            }.run,
            null,
        ),
    });
    promise_.resolve(3);
    const result = future.get(transform);
    try testing.expectEqual(9, result);
}

test "lazy future - detach" {
    var manual: executors.Manual = .{};

    const Ctx = struct {
        done: bool,

        pub fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @alignCast(@ptrCast(ctx.?));
            self.done = true;
        }
    };

    var ctx: Ctx = .{ .done = false };

    const f = future.submit(manual.executor(), Ctx.run, &ctx);
    try testing.expect(manual.isEmpty());
    try testing.expect(!ctx.done);

    try future.detach(f, std.testing.allocator);
    try testing.expect(!manual.isEmpty());
    try testing.expect(!ctx.done);

    _ = manual.drain();
    try testing.expect(manual.isEmpty());
    try testing.expect(ctx.done);
}

test "lazy future - contract - detach - promise first" {
    const allocator = testing.allocator;
    const future_, const promise_ = try future.contract(void, std.testing.allocator);
    const Ctx = struct {
        done: bool,
        pub fn run(
            ctx: ?*anyopaque,
            _: void,
        ) void {
            const self: *@This() = @alignCast(@ptrCast(ctx.?));
            self.done = true;
        }
    };
    var ctx: Ctx = .{ .done = false };
    const transform = future.pipeline(
        .{
            future_,
            future.via(executors.@"inline"),
            future.map(
                Ctx.run,
                &ctx,
            ),
        },
    );
    promise_.resolve({});
    try testing.expect(!ctx.done);
    try future.detach(transform, allocator);
    try testing.expect(ctx.done);
}

test "lazy future - contract - detach - future first" {
    const allocator = testing.allocator;
    const future_, const promise_ = try future.contract(void, std.testing.allocator);
    const Ctx = struct {
        done: bool,
        pub fn run(
            ctx: ?*anyopaque,
            _: void,
        ) void {
            const self: *@This() = @alignCast(@ptrCast(ctx.?));
            self.done = true;
        }
    };
    var ctx: Ctx = .{ .done = false };
    const transform = future.pipeline(
        .{
            future_,
            future.via(executors.@"inline"),
            future.map(
                Ctx.run,
                &ctx,
            ),
        },
    );
    try future.detach(transform, allocator);
    try testing.expect(!ctx.done);
    promise_.resolve({});
    try testing.expect(ctx.done);
}

test "lazy future - all" {
    const allocator = testing.allocator;
    var manual: executors.Manual = .{};
    const executor = manual.executor();
    const future_a, const promise_a = try future.contract(usize, std.testing.allocator);
    const future_b, const promise_b = try future.contract(u32, std.testing.allocator);
    const all = future.pipeline(
        .{
            future.just(),
            future.all(.{ future_a, future_b }),
        },
    );
    executor.submit(
        @TypeOf(promise_a).resolve,
        .{ &promise_a, @as(usize, 1) },
        allocator,
    );
    executor.submit(
        @TypeOf(promise_b).resolve,
        .{ &promise_b, @as(u32, 2) },
        allocator,
    );
    try testing.expectEqual(2, manual.drain());
    const result: std.meta.Tuple(&[_]type{ usize, u32 }) = future.get(all);
    const a, const b = result;
    try testing.expectEqual(1, a);
    try testing.expectEqual(2, b);
}

test "lazy future - first - a first" {
    const allocator = testing.allocator;
    var manual: executors.Manual = .{};
    const executor = manual.executor();
    const future_a, const promise_a = try future.contract(usize, std.testing.allocator);
    const future_b, const promise_b = try future.contract(u32, std.testing.allocator);
    const first = future.pipeline(
        .{
            future.just(),
            future.first(.{ future_a, future_b }),
        },
    );
    executor.submit(
        @TypeOf(promise_a).resolve,
        .{ &promise_a, @as(usize, 1) },
        allocator,
    );
    executor.submit(
        @TypeOf(promise_b).resolve,
        .{ &promise_b, @as(u32, 2) },
        allocator,
    );
    try testing.expectEqual(2, manual.drain());
    switch (future.get(first)) {
        .@"0" => |value_usize| {
            try std.testing.expectEqual(1, value_usize);
        },
        else => unreachable,
    }
}

test "lazy future - first - b first" {
    const allocator = testing.allocator;
    var manual: executors.Manual = .{};
    const executor = manual.executor();
    const future_a, const promise_a = try future.contract(usize, std.testing.allocator);
    const future_b, const promise_b = try future.contract(u32, std.testing.allocator);
    const first = future.pipeline(
        .{
            future.just(),
            future.first(.{ future_a, future_b }),
        },
    );
    executor.submit(
        @TypeOf(promise_b).resolve,
        .{ &promise_b, @as(u32, 2) },
        allocator,
    );
    try testing.expectEqual(1, manual.drain());
    switch (future.get(first)) {
        .@"1" => |value_u32| {
            try std.testing.expectEqual(2, value_u32);
        },
        else => unreachable,
    }
    executor.submit(
        @TypeOf(promise_a).resolve,
        .{ &promise_a, @as(usize, 1) },
        allocator,
    );
    try testing.expectEqual(1, manual.drain());
}

test "lazy future - pipline - threadpool - all" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    var tp: ThreadPool = try .init(1, allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();
    const executor = tp.executor();

    const future_a, const promise_a = try future.contract(usize, std.testing.allocator);
    const future_b, const promise_b = try future.contract(u32, std.testing.allocator);

    const Ctx = struct {
        thread_pool: *ThreadPool,
        const A_and_B = future.All(@TypeOf(.{ future_a, future_b })).OutputTupleType;
        fn map(
            ctx: ?*anyopaque,
            input: A_and_B,
        ) !A_and_B {
            const self: *@This() = @alignCast(@ptrCast(ctx));
            try std.testing.expectEqual(ThreadPool.current(), self.thread_pool);
            return input;
        }
    };
    var ctx: Ctx = .{ .thread_pool = &tp };
    const pipeline = future.pipeline(
        .{
            future.just(),
            future.via(executor),
            future.all(
                .{
                    future_a,
                    future_b,
                },
            ),
            future.via(executor),
            future.map(
                Ctx.map,
                &ctx,
            ),
        },
    );
    executor.submit(
        @TypeOf(promise_b).resolve,
        .{ &promise_b, @as(u32, 2) },
        allocator,
    );
    executor.submit(
        @TypeOf(promise_a).resolve,
        .{ &promise_a, @as(usize, 1) },
        allocator,
    );
    const result: std.meta.Tuple(&[_]type{ usize, u32 }) = try future.get(pipeline);
    const a, const b = result;
    try testing.expectEqual(1, a);
    try testing.expectEqual(2, b);
}

test "lazy future - pipline - threadpool - first" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const allocator = testing.allocator;
    var tp: ThreadPool = try .init(1, allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();
    const executor = tp.executor();

    const future_a, const promise_a = try future.contract(usize, std.testing.allocator);
    const future_b, const promise_b = try future.contract(u32, std.testing.allocator);

    const Ctx = struct {
        thread_pool: *ThreadPool,

        const FirstResultType = future.First(@TypeOf(.{ future_a, future_b })).OutputUnionType;
        fn map(
            ctx: ?*anyopaque,
            input: FirstResultType,
        ) !FirstResultType {
            const self: *@This() = @alignCast(@ptrCast(ctx));
            try std.testing.expectEqual(ThreadPool.current(), self.thread_pool);
            return input;
        }
    };
    var ctx: Ctx = .{ .thread_pool = &tp };
    const pipeline = future.pipeline(
        .{
            future.just(),
            future.via(executor),
            future.first(
                .{
                    future_a,
                    future_b,
                },
            ),
            future.via(executor),
            future.map(
                Ctx.map,
                &ctx,
            ),
        },
    );
    executor.submit(
        @TypeOf(promise_b).resolve,
        .{ &promise_b, @as(u32, 2) },
        allocator,
    );
    switch (try future.get(pipeline)) {
        .@"1" => |value_u32| {
            try std.testing.expectEqual(2, value_u32);
        },
        else => unreachable,
    }
    promise_a.resolve(1);
}

test "lazy future - box" {
    const allocator = testing.allocator;

    const AsyncReaderInterface = struct {
        const ReaderError = error{
            some_error,
        };
        const Vtable = struct {
            read: *const fn (self: *anyopaque) future.Boxed(ReaderError!u8),
        };
        ptr: *anyopaque,
        vtable: Vtable,

        pub inline fn read(self: @This()) future.Boxed(ReaderError!u8) {
            return self.vtable.read(self.ptr);
        }
    };

    const AsyncReader = struct {
        allocator: std.mem.Allocator,
        pub fn read(self: *@This()) future.Boxed(AsyncReaderInterface.ReaderError!u8) {
            return future.pipeline(
                .{
                    future.value(@as(AsyncReaderInterface.ReaderError!u8, 1)),
                    future.box(self.allocator),
                },
            );
        }

        pub fn eraseType(self: *@This()) AsyncReaderInterface {
            return .{
                .ptr = self,
                .vtable = .{
                    .read = @ptrCast(&read),
                },
            };
        }
    };
    var reader: AsyncReader = .{ .allocator = allocator };
    const async_reader = reader.eraseType();
    const result: u32 = try future.get(async_reader.read());
    try testing.expectEqual(1, result);
}
