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

// fn AnyChannel(T: type) type {
//     return union(enum) {
//         const Self = @This();
//         buffered: *Channel(T).Buffered,
//         rendezvous: *Channel(T),

//         pub fn fromRaw(channel_ptr: anytype) Self {
//             return switch (@TypeOf(channel_ptr.*)) {
//                 Channel(T).Buffered => Self{
//                     .buffered = channel_ptr,
//                 },
//                 Channel(T) => Self{
//                     .rendezvous = channel_ptr,
//                 },
//                 else => |UnknownChannel| @compileError(std.fmt.comptimePrint(
//                     "Unsupported channel type {s}}",
//                     .{@typeName(UnknownChannel)},
//                 )),
//             };
//         }
//     };
// }

// pub fn SelectOperation(Result: type) type {
//     return struct {
//         channel: AnyChannel(Result),
//     };
// }

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
            const A = @TypeOf(a.*);
            const B = @TypeOf(b.*);
            const Result = T;
            var awaiter: SelectAwaiter(A, B) = .{
                .locks = &[_]*SpinLock.Guard{ &first_lock, &second_lock },
                .channels = &[_]*Channel(Result){ a, b },
            };
            return Await(&awaiter);
        }
    }.select;
}

fn SelectAwaiter(A: type, B: type) type {
    const Result = SelectResult(A, B);
    return struct {
        const Self = @This();
        result: Result = undefined,
        fiber: *Fiber = undefined,
        locks: []const *SpinLock.Guard,
        channels: []const *Channel(Result),

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
            for (self.channels) |channel| {
                if (channel.peekHead()) |head| {
                    switch (head.operation) {
                        .send => |sender| {
                            self.result = sender.value.*;
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = sender.fiber,
                            };
                        },
                        else => @panic("todo"),
                    }
                }
            }
            return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
        }

        pub fn awaitResume(self: *Self, _: bool) Result {
            return self.result;
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
