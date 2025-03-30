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

fn Value(V: type) type {
    return struct {
        pub const ValueType = V;
        value: V,

        pub fn Computation(Continuation: anytype) type {
            return struct {
                next: Continuation,
                value: V,

                pub fn start(self: *@This()) void {
                    self.next.@"continue"(self.value, .{
                        .executor = InlineExecutor,
                    });
                }
            };
        }

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            return .{
                .next = continuation,
                .value = self.value,
            };
        }
    };
}

pub fn value(v: anytype) Value(@TypeOf(v)) {
    return .{ .value = v };
}
