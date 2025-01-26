const std = @import("std");
const log = std.log.scoped(.fiber_channel);
const assert = std.debug.assert;
const sync = @import("../../../sync/main.zig");
const SpinLock = sync.Spinlock;
const GenericAwait = @import("../../../await/main.zig");
const Awaiter = GenericAwait.Awaiter;
const Await = GenericAwait.@"await";
const Fiber = @import("../../main.zig");
const Channellike = @import("../main.zig").Channellike;

//TODO: support more than 2 channels
//TODO: support sending to channels in select also
pub fn select(
    a: anytype,
    b: anytype,
) SelectResult(@TypeOf(a.*), @TypeOf(b.*)) {
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
    const Result = SelectResult(A, B);
    var awaiter: SelectAwaiter(A, B) = .{
        .locks = &[_]*SpinLock.Guard{ &first_lock, &second_lock },
        .channels = &[_]Channellike(Result){ a.asChannellike(), b.asChannellike() },
    };
    return Await(&awaiter);
}

fn SelectAwaiter(A: type, B: type) type {
    const Result = SelectResult(A, B);
    return struct {
        const Self = @This();
        result: Result = undefined,
        fiber: *Fiber = undefined,
        locks: []const *SpinLock.Guard,
        channels: []const Channellike(Result),

        pub fn awaitReady(_: *Self) bool {
            return false;
        }

        pub fn awaitSuspend(
            ctx: *anyopaque,
            handle: *anyopaque,
        ) Awaiter.AwaitSuspendResult {
            const self: *Self = @alignCast(@ptrCast(ctx));
            self.fiber = @alignCast(@ptrCast(handle));
            for (self.channels) |_| {}
            return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
        }

        pub fn awaitResume(_: *Self, _: bool) Result {
            return std.mem.zeroes(Result);
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
