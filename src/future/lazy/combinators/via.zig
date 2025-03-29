const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../main.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../main.zig").core;
const Runnable = core.Runnable;
const future = @import("../main.zig");
const State = future.State;
const model = future.model;
const meta = future.meta;

const Via = @This();

next_executor: Executor,

pub fn PipeResult(T: type) type {
    return T;
}

fn ViaFuture(InputFuture: type) type {
    return struct {
        input_future: InputFuture,
        next_executor: Executor,

        pub const ValueType = InputValueType;
        const InputValueType = InputFuture.ValueType;

        pub const ContinuationForInputFuture = struct {
            input_value: InputValueType = undefined,
            pub fn @"continue"(
                self: *@This(),
                value: InputValueType,
                _: State,
            ) void {
                self.input_value = value;
            }
        };

        fn Computation(Continuation: anytype) type {
            return struct {
                input: InputFuture.ValueType,
                next_state: State,
                next: Continuation,

                pub fn start(self: *@This()) void {
                    self.next.@"continue"(
                        self.input,
                        self.next_state,
                    );
                }
            };
        }

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            var input_result: ContinuationForInputFuture = .{};
            var input_computation = self.input_future.materialize(&input_result);
            input_computation.start();
            return .{
                .input = input_result.input_value,
                .next_state = State{
                    .executor = self.next_executor,
                },
                .next = continuation,
            };
        }
    };
}

/// F<V> -> F<V>
pub fn pipe(
    self: *const Via,
    f: anytype,
) ViaFuture(@TypeOf(f)) {
    return .{
        .input_future = f,
        .next_executor = self.next_executor,
    };
}

pub fn via(executor: Executor) Via {
    return .{
        .next_executor = executor,
    };
}
