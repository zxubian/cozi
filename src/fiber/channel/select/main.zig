const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.fiber_channel_select);
const assert = std.debug.assert;
const sync = @import("../../../sync/main.zig");
const Spinlock = sync.Spinlock;
const GenericAwait = @import("../../../await/main.zig");
const Awaiter = GenericAwait.Awaiter;
const Await = GenericAwait.@"await";
const Fiber = @import("../../main.zig");
const channel_ = @import("../main.zig");
const PendingOperation = channel_.PendingOperation;
const fault = @import("../../../fault/main.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const meta = @import("./meta.zig");
const SelectResultType = meta.SelectResultType;
const Channels = meta.Channels;
const Channel = Fiber.Channel;
const ThreadExt = sync.Thread;

pub const SelectOperation = enum {
    receive,
    send,
};

pub const CASE_INDEX = u16;
pub const MAX_CASES = std.math.maxInt(CASE_INDEX);

pub fn select(cases: anytype) SelectResultType(@TypeOf(cases)) {
    const Cases = @TypeOf(cases);
    return Select(Cases).select(cases);
}

fn Select(Cases: type) type {
    const case_count = meta.caseCount(Cases);
    // const log_name = meta.selectName(Cases);
    const log_name = "";
    return struct {
        const Result = SelectResultType(Cases);

        const SelectAwaiter = struct {
            const Self = @This();

            // --- init parameters ---
            locks: []Spinlock.Guard,
            mutex: Spinlock,
            cases: Cases,

            // --- state ---
            result: Result = undefined,
            // hack, as tagged union memory layout is undefined
            result_case: CASE_INDEX = undefined,
            result_set: Atomic(bool) = .init(false),
            fiber: *Fiber = undefined,
            operations: []PendingOperation,

            pub fn awaitReady(_: *Self) bool {
                return false;
            }

            pub fn awaitSuspend(
                ctx: *anyopaque,
                handle: *anyopaque,
            ) Awaiter.AwaitSuspendResult {
                const self: *Self = @alignCast(@ptrCast(ctx));
                self.fiber = @alignCast(@ptrCast(handle));
                var guard = self.mutex.guard();
                guard.lock();
                defer {
                    log.debug("{s} {s}: releasing all locks", .{ self.fiber.name, log_name });
                    // var thread_name_buf: [std.Thread.max_name_len:0]u8 = undefined;
                    // const thread_name = ThreadExt.nameOrHandle(
                    //     ThreadExt.getCurrentThread().?,
                    //     &thread_name_buf,
                    // ) catch unreachable;
                    const thread_name = "";
                    unlockAll(
                        self.locks,
                        self.fiber.name,
                        thread_name,
                    );
                    guard.unlock();
                    log.debug("{s} {s}: finished releasing all locks", .{ self.fiber.name, log_name });
                }
                // set up all opertations & pointers
                inline for (0..case_count) |case_idx| {
                    const case = self.cases[case_idx];
                    const operation: SelectOperation = case[0];
                    // TODO: support sending in select
                    comptime assert(operation == .receive);
                    const channel = meta.channelFromCase(self.cases[case_idx]);
                    const T = @TypeOf(channel.*).ValueType;
                    self.result = meta.initResultType(
                        Result,
                        undefined,
                        case_idx,
                    );
                    const result_ptr: ?*T = switch (self.result) {
                        inline else => |*result| @alignCast(@ptrCast(result)),
                    };
                    self.operations[case_idx].operation = .{
                        .select_receive = .{
                            .result_ptr = @ptrCast(result_ptr),
                            .result_case = &self.result_case,
                            .this_case = case_idx,
                            .fiber = self.fiber,
                            .result_set = &self.result_set,
                        },
                    };
                }
                self.result = undefined;
                // pass 1: poll all channels to see if somebody is ready
                var random_order: RandomOrder(case_count) = .{};
                random_order.init();
                log.debug(
                    "{s} {s}: will poll channels in randomized order: {any}",
                    .{ self.fiber.name, log_name, random_order.shuffled },
                );
                while (random_order.next()) |i| {
                    switch (i) {
                        inline 0...case_count - 1 => |case_idx| {
                            const case = self.cases[case_idx];
                            const operation: SelectOperation = case[0];
                            // TODO: support sending in select
                            comptime assert(operation == .receive);
                            const channel = meta.channelFromCase(self.cases[case_idx]);
                            const T = @TypeOf(channel.*).ValueType;
                            const this_receiver = &self.operations[case_idx].operation.select_receive;
                            log.debug(
                                "{s} {s}: polling channel#{} {*}",
                                .{ self.fiber.name, log_name, i, channel },
                            );
                            if (channel.closed.load(.seq_cst)) {
                                log.debug(
                                    "{s}{s}: {*} is closed",
                                    .{ self.fiber.name, log_name, channel },
                                );
                                assert(this_receiver.trySet(T, null));
                                return .never_suspend;
                            }
                            if (channel.peekHead()) |head| {
                                switch (head.operation) {
                                    .send => |*send| {
                                        if (operation != .receive) {
                                            @panic("TODO");
                                        }
                                        log.debug(
                                            "{s} {s}: head of queue of {*} was a sender",
                                            .{ self.fiber.name, log_name, channel },
                                        );
                                        defer {
                                            _ = channel.pending_operations.popFront();
                                        }
                                        const value: *const T = @alignCast(@ptrCast(send.value));
                                        assert(this_receiver.trySet(T, value.*));
                                        // log.debug(
                                        //     "{s} {s}: will return: {}",
                                        //     .{ self.fiber.name, log_name, self.result },
                                        // );
                                        assert(send.value_taken.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null);
                                        send.fiber.scheduleSelf();
                                        return .never_suspend;
                                    },
                                    else => continue,
                                }
                            }
                        },
                        else => unreachable,
                    }
                }
                log.debug(
                    "{s} {s}: all channels were empty. Will park self in all channels & wait for sender on any channel",
                    .{ self.fiber.name, log_name },
                );
                // enqueue self on all channels
                inline for (0..case_count) |case_idx| {
                    const case = self.cases[case_idx];
                    const operation = &self.operations[case_idx];
                    const channel = meta.channelFromCase(case);
                    channel.pending_operations.pushBack(operation);
                }
                return .always_suspend;
            }

            pub fn awaitResume(self: *Self, suspended: bool) void {
                const thread_name = "";
                // // var thread_name_buf: [std.Thread.max_name_len:0]u8 = undefined;
                // const thread_name = ThreadExt.nameOrHandle(
                //     ThreadExt.getCurrentThread().?,
                //     &thread_name_buf,
                // ) catch unreachable;
                var guard = self.mutex.guard();
                guard.lock();
                defer guard.unlock();
                if (!suspended) {
                    log.debug(
                        "{s} {s}: resume without suspend.",
                        .{ self.fiber.name, log_name },
                    );
                    return;
                }
                log.debug(
                    "{s} {s}: resume from suspend on {s}",
                    .{ self.fiber.name, log_name, thread_name },
                );
                lockAll(self.locks, self.fiber.name, thread_name);
                defer {
                    log.debug("{s} {s}: release all locks on resume", .{ self.fiber.name, log_name });
                    unlockAll(
                        self.locks,
                        self.fiber.name,
                        thread_name,
                    );
                    log.debug("{s} {s}: finished releasing all locks on resume", .{ self.fiber.name, log_name });
                }
                // dequeue self from unsuccessful channels
                log.debug(
                    "{s} {s}: dequeue self from all channel waiting queues.",
                    .{ self.fiber.name, log_name },
                );
                inline for (0..case_count) |case_idx| {
                    const case = self.cases[case_idx];
                    const operation = &self.operations[case_idx];
                    const channel = meta.channelFromCase(case);
                    const T = @TypeOf(channel.*).ValueType;
                    const pending_operations = &channel.pending_operations;
                    pending_operations.remove(operation) catch {};
                    if (self.result_case == case_idx) {
                        log.debug("{s}: setting own result on resume. Case #{} Expected type = {s}", .{
                            self.fiber.name,
                            case_idx,
                            @typeName(T),
                        });
                        switch (operation.operation) {
                            .select_receive => |select_receive| {
                                // TODO: spurrious error here
                                assert(select_receive.result_set.load(.seq_cst));
                                // log.debug("{}", .{operation});
                                const result: *?T = @alignCast(@ptrCast(select_receive.result_ptr));
                                self.result = @unionInit(
                                    Result,
                                    std.fmt.comptimePrint("{}", .{case_idx}),
                                    result.*,
                                );
                            },
                            else => unreachable,
                        }
                    }
                }
            }

            pub fn awaiter(self: *Self) Awaiter {
                return Awaiter{
                    .ptr = self,
                    .vtable = .{
                        .await_suspend = awaitSuspend,
                    },
                };
            }
        };

        pub fn select(cases: Cases) Result {
            const fiber = Fiber.current().?;
            log.debug(
                "{s}: about to {s}",
                .{ fiber.name, log_name },
            );
            var operations: [case_count]PendingOperation = undefined;

            // Dining philosophers problem:
            // use resource heirarchy to avoid circular waiting.
            // Establish an order on the channels
            // by sorting on their pointer addresses.
            // Then, acquire spinlocks in that order.
            // --- get locks for all channels in order ---
            var locks: [case_count]Spinlock.Guard = undefined;
            sortLocks(cases, &locks);
            // var thread_name_buf: [std.Thread.max_name_len:0]u8 = undefined;
            // const thread_name = ThreadExt.nameOrHandle(
            //     ThreadExt.getCurrentThread().?,
            //     &thread_name_buf,
            // ) catch unreachable;
            const thread_name = "";
            log.debug(
                "{s} (running on {s})  about to acquire all locks for select",
                .{
                    fiber.name,
                    thread_name,
                },
            );
            lockAll(
                &locks,
                Fiber.current().?.name,
                thread_name,
            );
            log.debug(
                "{s} (running on {s})  acquired all locks for select",
                .{
                    fiber.name,
                    thread_name,
                },
            );
            var awaiter: SelectAwaiter = .{
                .locks = &locks,
                .cases = cases,
                .operations = &operations,
                .mutex = .{},
            };
            log.debug(
                "{s} {s} about to await on {*}",
                .{ fiber.name, log_name, &awaiter },
            );
            Await(&awaiter);
            log.debug(
                "{s} {s} returned from await. Result = {}",
                .{
                    Fiber.current().?.name,
                    log_name,
                    awaiter.result,
                },
            );
            return awaiter.result;
        }
    };
}

fn sortLocks(cases: anytype, locks: []Spinlock.Guard) void {
    if (locks.len != 2) {
        @panic("TODO");
    }
    const a = cases[0][1];
    const b = cases[1][1];
    const a_int = @intFromPtr(a);
    const b_int = @intFromPtr(b);
    const a_first = a_int < b_int;
    locks[0] = if (a_first) a.lock.guard() else b.lock.guard();
    locks[1] = if (a_first) b.lock.guard() else a.lock.guard();
}

fn lockAll(
    locks: []Spinlock.Guard,
    fiber_name: []const u8,
    thread_name: []const u8,
) void {
    for (locks) |*lock| {
        log.debug(
            "{s} ({s}) about to grab lock {*}",
            .{
                fiber_name,
                thread_name,
                @as(*anyopaque, @ptrCast(lock.spinlock)),
            },
        );
        lock.*.lock();
    }
}

fn unlockAll(
    locks: []Spinlock.Guard,
    fiber_name: []const u8,
    thread_name: []const u8,
) void {
    var i: usize = locks.len - 1;
    while (i < locks.len) : (i -%= 1) {
        const lock = &locks[i];
        log.debug(
            "{s} ({s}) about to release lock {*}",
            .{
                fiber_name,
                thread_name,
                @as(*anyopaque, @ptrCast(lock.spinlock)),
            },
        );
        lock.*.unlock();
    }
}

fn RandomOrder(comptime size: CASE_INDEX) type {
    return struct {
        /// TODO: reconsider where this should live
        threadlocal var random: ?std.Random.DefaultPrng = null;

        const Self = @This();
        shuffled: [size]CASE_INDEX = undefined,
        iterator_idx: CASE_INDEX = 0,

        pub fn init(self: *Self) void {
            for (&self.shuffled, 0..) |*idx, i| {
                idx.* = @intCast(i);
            }
            randomize(&self.shuffled);
        }

        pub fn next(self: *Self) ?CASE_INDEX {
            if (self.iterator_idx >= size) {
                return null;
            }
            const result = self.shuffled[self.iterator_idx];
            self.iterator_idx += 1;
            return result;
        }

        fn randomize(slice: []CASE_INDEX) void {
            if (random == null) {
                const seed: u64 = blk: {
                    if (builtin.is_test) {
                        break :blk std.testing.random_seed;
                    }
                    var bytes: u64 = undefined;
                    std.posix.getrandom(std.mem.asBytes(&bytes)) catch unreachable;
                    break :blk bytes;
                };
                random = std.Random.DefaultPrng.init(seed);
            }
            if (random) |*r| {
                r.random().shuffleWithIndex(CASE_INDEX, slice, CASE_INDEX);
            }
        }
    };
}

test {
    _ = @import("./tests.zig");
}
