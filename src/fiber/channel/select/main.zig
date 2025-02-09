const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.fiber_channel_select);
const assert = std.debug.assert;
const sync = @import("../../../sync/main.zig");
const SpinLock = sync.Spinlock;
const GenericAwait = @import("../../../await/main.zig");
const Awaiter = GenericAwait.Awaiter;
const Await = GenericAwait.@"await";
const Fiber = @import("../../main.zig");
const channel_ = @import("../main.zig");
const Channel = channel_.Channel;
const ChannelLike = channel_.Channellike;
const QueueElement = channel_.QueueElement;
const fault = @import("../../../fault/main.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

/// TODO: reconsider where this should live
threadlocal var random: ?std.Random.DefaultPrng = null;

//TODO: support more than 2 channels
//TODO: support sending to channels in select also
pub fn select(T: type) *const fn (a: *Channel(T), b: *Channel(T)) ?T {
    return struct {
        pub fn select(
            a: *Channel(T),
            b: *Channel(T),
        ) ?T {
            // Dining philosophers problem:
            // use resource heirarchy to avoid circular waiting.
            // Establish an order on the channels
            // by sorting on their pointer addresses.
            // Then, acquire spinlocks in that order.

            log.debug("About to select from: {*}, {*}", .{ a, b });
            // --- get locks for all channels in order ---
            const a_int = @intFromPtr(a);
            const b_int = @intFromPtr(b);
            const a_first = a_int < b_int;
            var first_lock: SpinLock.Guard = if (a_first) a.lock.guard() else b.lock.guard();
            var second_lock: SpinLock.Guard = if (a_first) b.lock.guard() else a.lock.guard();
            log.debug("Acquiring locks in order: {*} -> {*}", .{ if (a_first) a else b, if (a_first) b else a });
            first_lock.lock();
            second_lock.lock();
            log.debug("all locks acquired", .{});
            // ---
            const Result = T;
            var queue_elements: [2]QueueElement(T) = [_]QueueElement(T){undefined} ** 2;
            var awaiter: SelectAwaiter(T) = .{
                .locks = &[_]*SpinLock.Guard{ &first_lock, &second_lock },
                .channels = &[_]*Channel(Result){ a, b },
                .queue_elements = &queue_elements,
            };
            log.debug("about to await on {*}", .{&awaiter});
            Await(&awaiter);
            log.debug("returned from await. Result = {}", .{awaiter.result});
            return awaiter.result.value;
        }
    }.select;
}

pub fn ResultType(T: type) type {
    return struct {
        channel_index: usize,
        value: ?T,
    };
}

pub fn SelectAwaiter(Result: type) type {
    return struct {
        const Self = @This();
        // Used for consensus.
        // Note that this actually does not need to be atomic, because
        // any fiber which references this value will have the necessary locks.
        // However, we use Atomic here in preparation for lock-free select in the
        // future.
        result_set: Atomic(bool) = .init(false),
        result: ResultType(Result) = undefined,
        fiber: *Fiber = undefined,
        locks: []const *SpinLock.Guard,
        channels: []const *Channel(Result),
        queue_elements: []QueueElement(Result),

        pub fn awaitReady(_: *Self) bool {
            // for rendezvous channels:
            // even if there is a parked sending channel,
            // we should still suspend & do symmentric transfer to the sender
            // so, always return false here.
            return false;
        }

        pub fn awaitSuspend(
            ctx: *anyopaque,
            handle: *anyopaque,
        ) Awaiter.AwaitSuspendResult {
            const self: *Self = @alignCast(@ptrCast(ctx));
            self.fiber = @alignCast(@ptrCast(handle));
            defer {
                log.debug("{*}: releasing all locks", .{self});
                for (self.locks) |*guard| {
                    guard.*.unlock();
                }
            }
            // TODO: support >2 select branches
            // pass 1: poll all channels to see if somebody is ready
            var random_order = [_]u16{ 0, 1 };
            randomize(&random_order);
            log.debug(
                "{*}: will poll channels in randomized order: {any}",
                .{ self, random_order },
            );
            for (&random_order) |i| {
                const channel = self.channels[i];
                log.debug(
                    "{*}: polling channel#{} {*}",
                    .{ self, i, channel },
                );
                if (channel.closed.load(.seq_cst)) {
                    log.debug(
                        "{*}: {*} is closed",
                        .{ self, channel },
                    );
                    if (self.result_set.cmpxchgStrong(
                        false,
                        true,
                        .seq_cst,
                        .seq_cst,
                    )) |_| {
                        // cannot happen, because we're not enqueued yet,
                        // so the node is not accessible to other fibers.
                        unreachable;
                    }
                    self.result = .{
                        .channel_index = i,
                        .value = null,
                    };
                    return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
                }
                if (channel.peekHead()) |head| {
                    switch (head.operation) {
                        .send => |*send| {
                            log.debug(
                                "{*}: head of queue of {*} was a sender",
                                .{ self, channel },
                            );
                            defer {
                                _ = channel.parked_fibers.popFront();
                            }
                            if (self.result_set.cmpxchgStrong(
                                false,
                                true,
                                .seq_cst,
                                .seq_cst,
                            )) |_| {
                                // cannot happen, because we're not enqueued yet,
                                // so the node is not accessible to other fibers.
                                unreachable;
                            }
                            const sender = send.awaiter();
                            self.result = .{
                                .channel_index = i,
                                .value = sender.value.*,
                            };
                            log.debug(
                                "{*}: will return: {}",
                                .{ self, self.result },
                            );
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = sender.fiber,
                            };
                        },
                        else => continue,
                    }
                }
            }
            log.debug(
                "{*}: all channels were empty. Will park self in all channels & wait for sender on any channel",
                .{self},
            );
            // enqueue self on all channels
            for (self.channels, self.queue_elements) |channel, *queue_element| {
                queue_element.* = QueueElement(Result){
                    .intrusive_list_node = .{},
                    .operation = .{
                        .select_receive = self,
                    },
                };
                channel.parked_fibers.pushBack(queue_element);
            }
            return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
        }

        pub fn awaitResume(self: *Self, suspended: bool) void {
            if (!suspended) return;
            log.debug("{*}: resume from suspend. Reacquire all locks", .{self});
            for (self.locks) |*guard| {
                guard.*.lock();
            }
            defer {
                log.debug("{*}: release all locks", .{self});
                for (self.locks) |guard| {
                    guard.unlock();
                }
            }
            // dequeue self from unsuccessful channels
            log.debug("{*}: dequeue self from all channel waiting queues.", .{self});
            for (
                self.channels,
                self.queue_elements,
            ) |
                channel,
                *queue_element,
            | {
                const parked_fibers = &channel.parked_fibers;
                parked_fibers.remove(queue_element) catch continue;
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

        pub fn findChannelIndex(self: *Self, channel: *Channel(Result)) ?usize {
            return std.mem.indexOfScalar(*Channel(Result), self.channels, channel);
        }
    };
}

const MAX_SELECT_BRANCHES = std.math.maxInt(u16);

fn randomize(slice: anytype) void {
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
        r.random().shuffleWithIndex(u16, slice, u16);
    }
}

fn SelectResult(A: anytype, B: anytype) type {
    for (&.{ A, B }) |T| {
        if (!isChannelLike(T)) {
            @compileError(std.fmt.comptimePrint(
                "{} is does not implement the Channel API.",
                .{@typeName(T)},
            ));
        }
    }
    const ValueTypeA = A.ValueType;
    const ValueTypeB = B.ValueType;
    if (ValueTypeA != ValueTypeB) {
        @compileError("TODO");
    }
    return ValueTypeA;
}

fn isChannelLike(T: type) bool {
    _ = T;
    return true;
}

test {
    _ = @import("./tests.zig");
}
