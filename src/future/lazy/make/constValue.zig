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

fn ConstValue(comptime v: anytype) type {
    const V = @TypeOf(v);
    return struct {
        pub const ValueType = V;

        pub fn Computation(Continuation: type) type {
            return struct {
                next: Continuation,
                input: void = undefined,

                pub fn start(self: *@This()) void {
                    self.next.@"continue"(
                        v,
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

        pub fn awaitable(self: @This()) future.lazy.Awaitable(@This()) {
            return .{
                .future = self,
            };
        }
    };
}

/// Future that instantly returns comptime-known value `v`
/// * -> Future<V>
pub fn constValue(comptime v: anytype) ConstValue(v) {
    return .{};
}
