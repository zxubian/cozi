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
const meta = future.meta;

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
    };
}

/// Future that instantly returns comptime-known value `v`
pub fn constValue(comptime v: anytype) ConstValue(v) {
    return .{};
}
