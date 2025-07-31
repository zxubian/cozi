const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const cozi = @import("../../../root.zig");
const log = cozi.core.log.scoped(.fiber_channel_select);
const Fiber = cozi.Fiber;
const sync = cozi.sync;
const Spinlock = sync.Spinlock;
const generic_await = cozi.await;
const Awaiter = generic_await.Awaiter;
const Await = generic_await.await;
const Worker = generic_await.Worker;
const channel_ = @import("../root.zig");
const PendingOperation = channel_.PendingOperation;
const fault = cozi.fault;
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const meta = @import("./meta.zig");
const SelectResultType = meta.SelectResultType;
const Channels = meta.Channels;
const Channel = Fiber.Channel;
const ThreadExt = sync.Thread;

pub const SelectOperation = enum {
    receive,
    /// TODO:
    send,
};

pub const CASE_INDEX = u16;
pub const MAX_CASES = std.math.maxInt(CASE_INDEX);

/// Wait on multiple channel operations
/// Polls channels in a random order, and returns the first available result.
/// If no channels are ready to produce a result, parks the current fiber
/// until a result is ready.
/// The number and type of cases must be comptime-known.
pub fn select(cases: anytype) SelectResultType(@TypeOf(cases)) {
    const Cases = @TypeOf(cases);
    return Select(Cases).select(cases);
}

fn Select(Cases: type) type {
    const case_count = meta.caseCount(Cases);
    const log_name = meta.selectName(Cases);
    return struct {
        const Result = SelectResultType(Cases);

        const SelectAwaiter = struct {
            const Self = @This();

            // --- init parameters ---
            locks: []*Spinlock,
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
                self: *@This(),
                handle: Worker,
            ) Awaiter.AwaitSuspendResult {
                assert(handle.type == .fiber);
                self.fiber = @alignCast(@ptrCast(handle.ptr));
                var guards: [case_count]Spinlock.Guard = undefined;
                lockAll(self.locks, &guards);
                defer {
                    unlockAll(&guards);
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
                                    "{s} {s}: {*} is closed",
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
                if (!suspended) unreachable;
                log.debug(
                    "{s} {s}: resume from suspend",
                    .{ self.fiber.name, log_name },
                );
                var guards: [case_count]Spinlock.Guard = undefined;
                lockAll(self.locks, &guards);
                defer {
                    unlockAll(&guards);
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
                                assert(select_receive.result_set.load(.seq_cst));
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
                        .await_suspend = @ptrCast(&awaitSuspend),
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
            var locks: [case_count]*Spinlock = undefined;
            sortLocks(cases, &locks);
            var awaiter: SelectAwaiter = .{
                .locks = &locks,
                .cases = cases,
                .operations = &operations,
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

/// sort locks in order of pointer address
fn sortLocks(cases: anytype, locks: []*Spinlock) void {
    if (locks.len != 2) {
        @panic("TODO");
    }
    const a = cases[0][1];
    const b = cases[1][1];
    const a_int = @intFromPtr(a);
    const b_int = @intFromPtr(b);
    const a_first = a_int < b_int;
    locks[0] = if (a_first) &a.lock else &b.lock;
    locks[1] = if (a_first) &b.lock else &a.lock;
}

fn lockAll(
    locks: []*Spinlock,
    guards: []Spinlock.Guard,
) void {
    for (locks, guards) |lock, *guard| {
        guard.* = lock.guard();
        guard.*.lock();
    }
}

fn unlockAll(
    locks: []Spinlock.Guard,
) void {
    var i: usize = locks.len - 1;
    while (i < locks.len) : (i -%= 1) {
        const lock = &locks[i];
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
