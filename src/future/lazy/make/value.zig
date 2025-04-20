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

pub fn Future(V: type) type {
    return struct {
        pub const ValueType = V;
        value: ValueType,

        pub fn Computation(Continuation: anytype) type {
            return struct {
                next: Continuation,
                input: V,

                pub fn start(self: *@This()) void {
                    self.next.@"continue"(
                        self.input,
                        .{
                            .executor = InlineExecutor,
                        },
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
    };
}

///Future that instantly returns runtime-known value `v`
pub fn value(v: anytype) Future(@TypeOf(v)) {
    return .{ .value = v };
}
