const std = @import("std");
const log = std.log.scoped(.fiber_channel);
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

            // get locks for all channels in order
            const a_int = @intFromPtr(a);
            const b_int = @intFromPtr(b);
            var first_lock: SpinLock.Guard = if (a_int < b_int) a.lock.guard() else b.lock.guard();
            var second_lock: SpinLock.Guard = if (a_int < b_int) b.lock.guard() else a.lock.guard();
            first_lock.lock();
            second_lock.lock();
            //
            const Result = T;
            var queue_elements: [2]QueueElement(T) = [_]QueueElement(T){undefined} ** 2;
            var awaiter: SelectAwaiter(T) = .{
                .locks = &[_]*SpinLock.Guard{ &first_lock, &second_lock },
                .channels = &[_]*Channel(Result){ a, b },
                .queue_elements = &queue_elements,
            };
            Await(&awaiter);
            return awaiter.result;
        }
    }.select;
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
        result: ?Result = undefined,
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
            // pass 1: poll all channels to see if somebody is ready
            defer {
                for (self.locks) |*guard| {
                    guard.*.unlock();
                }
            }
            // TODO: randomize polling order
            for (self.channels) |channel| {
                if (channel.closed) {
                    if (self.result_set.cmpxchgStrong(false, true, .seq_cst, .seq_cst)) |_| {
                        @panic("todo");
                    }
                    self.result = null;
                    return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
                }
                if (channel.peekHead()) |head| {
                    switch (head.operation) {
                        .send => |*send| {
                            defer _ = channel.parked_fibers.popFront();
                            // TODO
                            if (self.result_set.cmpxchgStrong(
                                false,
                                true,
                                .seq_cst,
                                .seq_cst,
                            )) |_| {
                                @panic("TODO");
                            }
                            const sender = send.awaiter();
                            self.result = sender.value.*;
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = sender.fiber,
                            };
                        },
                        else => @panic("todo"),
                    }
                }
            }
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
            for (self.locks) |*guard| {
                guard.*.lock();
            }
            defer {
                for (self.locks) |guard| {
                    guard.unlock();
                }
            }
            // dequeue self from unsuccessful channels
            for (
                self.channels,
                self.queue_elements,
            ) |
                channel,
                *queue_element,
            | {
                const parked_fibers = &channel.parked_fibers;
                const next_element = queue_element.intrusive_list_node.next;
                const previous_element = parked_fibers.findPrevious(queue_element) catch continue;
                if (previous_element) |previous| {
                    previous.intrusive_list_node.next = next_element;
                } else {
                    assert(parked_fibers.head == &queue_element.intrusive_list_node);
                    _ = parked_fibers.popFront();
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
    const ValueTypeB = A.ValueType;
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
