const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../../root.zig");
const executors = cozi.executors;
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future.lazy;

const Just = @This();
pub const ValueType = void;

pub fn Computation(Continuation: type) type {
    return struct {
        next: Continuation,

        pub fn init(self: *@This()) void {
            self.next.init();
        }

        pub fn start(self: *@This()) void {
            self.next.@"continue"({}, .init);
        }
    };
}

pub fn materialize(
    _: @This(),
    continuation: anytype,
) Computation(@TypeOf(continuation)) {
    return .{
        .next = continuation,
    };
}

/// A Future that instantly returns nothing
/// * -> Future<void>
///
/// Equivalent to `constValue({})`
pub fn just() Just {
    return .{};
}

pub fn awaitable(self: Just) future.Awaitable(Just) {
    return .{ .future = self };
}
