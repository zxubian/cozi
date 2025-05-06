const std = @import("std");
const assert = std.debug.assert;
const cozi = @import("../../../root.zig");
const executors = cozi.executors;
const InlineExecutor = executors.@"inline";
const Executor = executors.Executor;
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future;
const State = future.State;

pub fn Future(V: type) type {
    return struct {
        pub const ValueType = V;
        value: ValueType,

        pub fn Computation(Continuation: type) type {
            return struct {
                next: Continuation,
                input: V,

                pub fn start(self: *@This()) void {
                    self.next.@"continue"(
                        self.input,
                        .init,
                    );
                }
            };
        }

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            return .{
                .input = self.value,
                .next = continuation,
            };
        }

        pub fn awaitable(self: @This()) future.lazy.Awaitable(@This()) {
            return .{
                .future = self,
            };
        }
    };
}

///`Future` that instantly returns runtime-known value `v`
/// * -> Future<V>
pub fn value(v: anytype) Future(@TypeOf(v)) {
    return .{ .value = v };
}
