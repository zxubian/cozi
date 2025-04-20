const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../root.zig").executors;
const InlineExecutor = executors.@"inline";
const Executor = executors.Executor;
const core = @import("../../../root.zig").core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
const State = future.State;
const model = future.model;
const meta = future.meta;

const Just = @This();
pub const ValueType = void;

pub fn Computation(Continuation: type) type {
    return struct {
        next: Continuation,

        pub fn start(self: *@This()) void {
            self.next.@"continue"(
                {},
                .{
                    .executor = InlineExecutor,
                },
            );
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

///Future that instantly returns void
pub fn just() Just {
    return .{};
}
