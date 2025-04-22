const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../root.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../root.zig").core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
const State = future.State;
const model = future.model;
const meta = future.meta;

const Via = @This();

next_executor: Executor,

pub fn Future(InputFuture: type) type {
    return struct {
        input_future: InputFuture,
        next_executor: Executor,

        pub const ValueType = InputFuture.ValueType;

        pub fn Computation(Continuation: type) type {
            return struct {
                input_computation: InputFuture.Computation(ContinuationForInputFuture),

                pub fn start(self: *@This()) void {
                    self.input_computation.start();
                }

                pub const ContinuationForInputFuture = struct {
                    next_executor: Executor,
                    next: Continuation,
                    pub fn @"continue"(
                        self: *@This(),
                        value: InputFuture.ValueType,
                        _: State,
                    ) void {
                        self.next.@"continue"(
                            value,
                            .{
                                .executor = self.next_executor,
                            },
                        );
                    }
                };
            };
        }

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            const Result = Computation(@TypeOf(continuation));
            const InputContinuation = Result.ContinuationForInputFuture;
            return .{
                .input_computation = self.input_future.materialize(
                    InputContinuation{
                        .next_executor = self.next_executor,
                        .next = continuation,
                    },
                ),
            };
        }
    };
}

/// F<V> -> F<V>
pub fn pipe(
    self: *const Via,
    f: anytype,
) Future(@TypeOf(f)) {
    return .{
        .input_future = f,
        .next_executor = self.next_executor,
    };
}

/// Sets the Executor for Futures succeeding in the pipeline.
/// Forwards the resolved value of the previous future as-is.
/// Cannot be the first Future in a pipeline (must follow some other Future).
pub fn via(executor: Executor) Via {
    return .{
        .next_executor = executor,
    };
}
