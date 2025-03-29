const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../main.zig").executors;
const InlineExecutor = executors.@"inline";
const Executor = executors.Executor;
const core = @import("../../../main.zig").core;
const Runnable = core.Runnable;
const future = @import("../main.zig");
const State = future.State;
const model = future.model;
const Computation = model.Computation;
const meta = future.meta;

const Just = struct {
    pub const ValueType = void;

    fn JustComputation(Continuation: anytype) type {
        return struct {
            continuation: Continuation,

            pub fn start(self: *@This()) void {
                self.continuation.@"continue"({}, .{
                    .executor = InlineExecutor,
                });
            }
        };
    }

    pub fn materialize(
        _: *@This(),
        continuation: anytype,
    ) Computation(JustComputation(@TypeOf(continuation))) {
        return .{
            .continuation = continuation,
        };
    }
};

pub fn just() Just {
    return .{};
}
