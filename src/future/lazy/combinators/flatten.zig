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

const Flatten = @This();

pub fn Future(InputFuture: type) type {
    const OuterFuture = InputFuture;
    const InnerFuture = InputFuture.ValueType;
    const FlattenedValue = InnerFuture.ValueType;
    return struct {
        input_future: OuterFuture,
        pub const ValueType = FlattenedValue;

        pub fn Computation(Continuation: type) type {
            return struct {
                input_computation: OuterFuture.Computation(OuterFutureContinuation),

                pub fn start(self: *@This()) void {
                    self.input_computation.start();
                }

                pub const OuterFutureContinuation = struct {
                    inner_future: InnerFuture = undefined,
                    state: State = undefined,
                    runnable: Runnable = undefined,
                    inner_future_computation: InnerFuture.Computation(InnerFutureContinuation) = undefined,
                    next: Continuation,

                    pub fn @"continue"(
                        self: *@This(),
                        value: InnerFuture,
                        state: State,
                    ) void {
                        self.inner_future = value;
                        self.state = state;
                        self.inner_future_computation = self.inner_future.materialize(
                            InnerFutureContinuation{
                                .next_ptr = &self.next,
                            },
                        );
                        self.inner_future_computation.start();
                    }

                    pub const InnerFutureContinuation = struct {
                        next_ptr: *Continuation,

                        pub fn @"continue"(
                            self: *@This(),
                            value: FlattenedValue,
                            state: State,
                        ) void {
                            self.next_ptr.@"continue"(value, state);
                        }
                    };
                };
            };
        }

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            const Result = Computation(@TypeOf(continuation));
            const InputContinuation = Result.OuterFutureContinuation;
            return .{
                .input_computation = self.input_future.materialize(
                    InputContinuation{
                        .next = continuation,
                    },
                ),
            };
        }
    };
}

pub fn pipe(
    _: @This(),
    f: anytype,
) Future(@TypeOf(f)) {
    return .{
        .input_future = f,
    };
}

/// Future<Future<T>> -> Future<T>
pub fn flatten() Flatten {
    return .{};
}
