const std = @import("std");
const testing = std.testing;

const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;
const Await = cozi.await;
const Awaiter = Await.Awaiter;
const await = Await.await;
const executors = cozi.executors;
const ManualExecutor = executors.Manual;
const future = cozi.future.lazy;
const ThreadPool = cozi.executors.threadPools.Compute;
const FiberPool = cozi.executors.FiberPool;

test "fiber - future - just" {
    const allocator = testing.allocator;
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        pub fn run() !void {
            const f = future.just();
            await(&f);
        }
    };
    try Fiber.go(
        Ctx.run,
        .{},
        allocator,
        manual.executor(),
    );
    _ = manual.drain();
}

test "fiber - future - value" {
    const allocator = testing.allocator;
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        pub fn run() !void {
            const f = future.value(@as(usize, 123));
            const result = await(&f);
            try testing.expectEqual(123, result);
        }
    };
    try Fiber.go(
        Ctx.run,
        .{},
        allocator,
        manual.executor(),
    );
    _ = manual.drain();
}

test "fiber - future - constValue" {
    const allocator = testing.allocator;
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        pub fn run() !void {
            const f = future.constValue(@as(usize, 123));
            const result = await(&f);
            try testing.expectEqual(123, result);
        }
    };
    try Fiber.go(
        Ctx.run,
        .{},
        allocator,
        manual.executor(),
    );
    _ = manual.drain();
}

test "fiber - future - contract" {
    const allocator = testing.allocator;
    var manual: ManualExecutor = .{};
    const Ctx = struct {
        producer_done: bool = false,
        consumer_done: bool = false,
        contract: future.Contract(u32).Tuple,

        pub fn producer(ctx: *@This()) void {
            _, const promise = ctx.contract;
            promise.resolve(123);
            ctx.producer_done = true;
        }

        pub fn consumer(ctx: *@This()) !void {
            const result = await(&ctx.contract[0]);
            try testing.expectEqual(123, result);
            ctx.consumer_done = true;
        }
    };
    var ctx: Ctx = .{
        .contract = try future.contract(u32, allocator),
    };
    try Fiber.goWithName(
        Ctx.consumer,
        .{&ctx},
        allocator,
        manual.executor(),
        "Consumer",
    );
    _ = manual.drain();
    try testing.expect(!ctx.producer_done);
    try testing.expect(!ctx.consumer_done);
    try Fiber.goWithName(
        Ctx.producer,
        .{&ctx},
        allocator,
        manual.executor(),
        "Producer",
    );
    _ = manual.drain();
    try testing.expect(ctx.producer_done);
    try testing.expect(ctx.consumer_done);
}

test "fiber - future - pipeline basic" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};
    var future_executor: ManualExecutor = .{};

    const Ctx = struct {
        done: bool = false,
        future_executor: executors.Executor,
        pub fn run(ctx: *@This()) !void {
            const pipeline = future.pipeline(
                .{
                    future.value(@as(usize, 123)),
                    future.via(ctx.future_executor),
                    future.map(
                        struct {
                            pub fn map(input: usize) usize {
                                return input + 1;
                            }
                        }.map,
                        .{},
                    ),
                },
            );
            const result = await(&pipeline);
            try testing.expectEqual(124, result);
            ctx.done = true;
        }
    };
    var ctx: Ctx = .{
        .future_executor = future_executor.executor(),
    };
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
    try testing.expect(!ctx.done);
    _ = future_executor.drain();
    try testing.expect(fiber_executor.count() > 0);
    _ = fiber_executor.drain();
    try testing.expect(ctx.done);
}

test "fiber - future - submit" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};
    var future_executor: ManualExecutor = .{};

    const Ctx = struct {
        inner_done: bool = false,
        done: bool = false,
        future_executor: executors.Executor,
        pub fn run(ctx: *@This()) !void {
            const Impl = @This();
            const submit = future.submit(
                ctx.future_executor,
                struct {
                    pub fn innerRun(self: *Impl) void {
                        self.inner_done = true;
                    }
                }.innerRun,
                .{ctx},
            );
            await(&submit);
            try testing.expect(ctx.inner_done);
            ctx.done = true;
        }
    };
    var ctx: Ctx = .{
        .future_executor = future_executor.executor(),
    };
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
    try testing.expect(!ctx.done);
    try testing.expect(!ctx.inner_done);
    _ = future_executor.drain();
    try testing.expect(fiber_executor.count() > 0);
    _ = fiber_executor.drain();
    try testing.expect(ctx.done);
    try testing.expect(ctx.inner_done);
}

test "fiber - future - MapOk" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};

    const Ctx = struct {
        pub fn run() !void {
            const pipeline = future.pipeline(
                .{
                    future.value(@as(anyerror!u32, 123)),
                    future.mapOk(
                        struct {
                            pub fn run(
                                in: u32,
                            ) u32 {
                                return in + 1;
                            }
                        }.run,
                        .{},
                    ),
                },
            );
            const result = await(&pipeline);
            try testing.expectEqual(124, result);
        }
    };

    try Fiber.go(
        Ctx.run,
        .{},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
}

test "fiber - future - andThen" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};

    const Ctx = struct {
        pub fn run() !void {
            const IoError = error{
                file_not_found,
            };
            const pipeline = future.pipeline(
                .{
                    future.constValue(@as(IoError!u32, 123)),
                    future.andThen(
                        struct {
                            pub fn run(
                                input: u32,
                            ) future.Value(IoError!u32) {
                                return future.value(@as(IoError!u32, input + 1));
                            }
                        }.run,
                        .{},
                    ),
                },
            );
            const result = await(&pipeline);
            try testing.expectEqual(124, result);
        }
    };

    try Fiber.go(
        Ctx.run,
        .{},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
}

test "fiber - future - orElse" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};

    const Ctx = struct {
        pub fn run() !void {
            const IoError = error{
                file_not_found,
            };
            const pipeline = future.pipeline(
                .{
                    future.constValue(@as(IoError!u32, IoError.file_not_found)),
                    future.orElse(
                        struct {
                            pub fn run(
                                _: IoError,
                            ) future.Value(u32) {
                                return future.value(@as(u32, 123));
                            }
                        }.run,
                        .{},
                    ),
                },
            );
            const result = await(&pipeline);
            try testing.expectEqual(123, result);
        }
    };

    try Fiber.go(
        Ctx.run,
        .{},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
}

test "fiber - future - pipeline combinators" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};

    const Ctx = struct {
        pub fn run() !void {
            const IoError = error{
                file_not_found,
            };
            const pipeline = future.pipeline(
                .{
                    future.just(),
                    future.map(
                        struct {
                            pub fn run() IoError!u32 {
                                return 3;
                            }
                        }.run,
                        .{},
                    ),
                    future.orElse(
                        struct {
                            pub fn run(_: IoError) future.Value(u32) {
                                unreachable;
                            }
                        }.run,
                        .{},
                    ),
                    future.andThen(
                        struct {
                            pub fn run(_: u32) future.Value(IoError!u32) {
                                return future.value(@as(
                                    IoError!u32,
                                    IoError.file_not_found,
                                ));
                            }
                        }.run,
                        .{},
                    ),
                    future.andThen(
                        struct {
                            pub fn run(_: u32) future.Value(IoError!u32) {
                                unreachable;
                            }
                        }.run,
                        .{},
                    ),
                    future.orElse(
                        struct {
                            pub fn run(err: IoError) future.Value(IoError!u32) {
                                std.debug.assert(IoError.file_not_found == err);
                                return future.value(@as(IoError!u32, 3));
                            }
                        }.run,
                        .{},
                    ),
                    future.mapOk(
                        struct {
                            pub fn run(in: u32) u32 {
                                return in + 1;
                            }
                        }.run,
                        .{},
                    ),
                },
            );
            const result = try await(&pipeline);
            try testing.expectEqual(4, result);
        }
    };

    try Fiber.go(
        Ctx.run,
        .{},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
}

test "fiber - future - all" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};
    var future_executor: ManualExecutor = .{};

    const Futures = struct {
        pub fn run1() usize {
            return 123;
        }

        pub fn run2() []const u8 {
            return "abc";
        }
    };

    const Ctx = struct {
        done: bool = false,
        future_executor: executors.Executor,
        pub fn run(ctx: *@This()) !void {
            const submit1 = future.submit(ctx.future_executor, Futures.run1, .{});
            const submit2 = future.submit(ctx.future_executor, Futures.run2, .{});
            const all = future.pipeline(
                .{
                    future.just(),
                    future.via(ctx.future_executor),
                    future.all(
                        .{
                            submit1,
                            submit2,
                        },
                    ),
                },
            );
            const int, const string = await(&all);
            try testing.expectEqual(123, int);
            try testing.expectEqualStrings("abc", string);
            ctx.done = true;
        }
    };
    var ctx: Ctx = .{
        .future_executor = future_executor.executor(),
    };
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
    try testing.expect(!ctx.done);
    _ = future_executor.drain();
    try testing.expect(fiber_executor.count() > 0);
    _ = fiber_executor.drain();
    try testing.expect(ctx.done);
}

test "fiber - future - first" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};
    var future_executor: ManualExecutor = .{};
    var first_executor: ManualExecutor = .{};
    var second_executor: ManualExecutor = .{};

    const Futures = struct {
        pub fn run1() usize {
            return 123;
        }

        pub fn run2() []const u8 {
            return "abc";
        }
    };

    const Ctx = struct {
        done: bool = false,
        future_executor: executors.Executor,
        first_executor: executors.Executor,
        second_executor: executors.Executor,
        pub fn run(ctx: *@This()) !void {
            const submit1 = future.submit(
                ctx.second_executor,
                Futures.run1,
                .{},
            );
            const submit2 = future.submit(
                ctx.first_executor,
                Futures.run2,
                .{},
            );
            const first = future.pipeline(
                .{
                    future.just(),
                    future.via(ctx.future_executor),
                    future.first(
                        .{
                            submit1,
                            submit2,
                        },
                    ),
                },
            );
            const result = await(&first);
            switch (result) {
                .@"0" => |_| unreachable,
                .@"1" => |string| try testing.expectEqualStrings("abc", string),
            }
            ctx.done = true;
        }
    };
    var ctx: Ctx = .{
        .future_executor = future_executor.executor(),
        .first_executor = first_executor.executor(),
        .second_executor = second_executor.executor(),
    };
    try Fiber.go(
        Ctx.run,
        .{&ctx},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
    try testing.expect(!ctx.done);
    _ = future_executor.drain();
    try testing.expect(!ctx.done);
    try testing.expect(first_executor.count() > 0);
    try testing.expect(second_executor.count() > 0);
    _ = first_executor.drain();
    _ = second_executor.drain();
    try testing.expect(fiber_executor.count() > 0);
    _ = fiber_executor.drain();
    try testing.expect(ctx.done);
}

test "fiber - future - box" {
    const allocator = testing.allocator;
    var fiber_executor: ManualExecutor = .{};

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

    const FiberCtx = struct {
        reader: AsyncReader,
        done: bool,

        pub fn run(ctx: *@This()) !void {
            const async_reader = ctx.reader.eraseType();
            const result: u32 = try await(&async_reader.read());
            try testing.expectEqual(1, result);
            ctx.done = true;
        }
    };
    var ctx: FiberCtx = .{
        .reader = .{ .allocator = allocator },
        .done = false,
    };
    try Fiber.go(
        FiberCtx.run,
        .{&ctx},
        allocator,
        fiber_executor.executor(),
    );
    _ = fiber_executor.drain();
    try testing.expect(ctx.done);
}

test "fiber - future - await" {
    var tp: ThreadPool = undefined;
    try tp.init(
        1,
        testing.allocator,
    );
    defer tp.deinit();
    tp.start();
    defer tp.stop();
    var fiber_pool: FiberPool = undefined;
    try fiber_pool.init(
        testing.allocator,
        tp.executor(),
        .{
            .fiber_count = 1,
        },
    );
    defer fiber_pool.deinit();
    fiber_pool.start();
    defer fiber_pool.stop();
    const Ctx = struct {
        pub fn a() u32 {
            return 42;
        }
    };
    const f = future.submit(fiber_pool.executor(), Ctx.a, .{});
    const result = await(&f);
    try testing.expectEqual(@as(u32, 42), result);
}
