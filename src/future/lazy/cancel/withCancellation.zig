const std = @import("std");
const cozi = @import("../../../root.zig");
const testing = std.testing;
const executors = cozi.executors;
const ManualExecutor = executors.Manual;
const assert = std.debug.assert;
const Executor = executors.Executor;
const core = cozi.core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
const model = future.model;
const meta = future.meta;
const cancel = future.cancellation;

const WithCancellation = @This();

token: cancel.Token,

pub fn Future(InputFuture: type) type {
    return struct {
        input_future: InputFuture,
        token: cancel.Token,

        pub const ValueType = cancel.CancellationError!InputFuture.ValueType;

        pub fn Computation(Continuation: type) type {
            return struct {
                input_computation: InputComputation,
                runnable: Runnable = undefined,
                next: Continuation,
                token: cancel.Token,

                const State = enum {
                    init,
                    resolved,
                    cancelled,
                };

                const Impl = @This();
                const InputComputation = InputFuture.Computation(InputContinuation);

                pub fn start(self: *Impl) void {
                    if (self.token.isCancelled()) {
                        self.next.@"continue"(
                            cancel.CancellationError.canceled,
                            .init,
                        );
                        return;
                    }
                    self.input_computation.start();
                }

                pub fn run(ctx_: *anyopaque) void {
                    const input_continuation: *InputContinuation = @alignCast(@ptrCast(ctx_));
                    const input_computation: *InputComputation = @fieldParentPtr("next", input_continuation);
                    const self: *Impl = @fieldParentPtr("input_computation", input_computation);
                    if (self.token.isCancelled()) {
                        self.next.@"continue"(
                            cancel.CancellationError.canceled,
                            .init,
                        );
                        return;
                    }
                    self.next.@"continue"(
                        input_continuation.value,
                        input_continuation.state,
                    );
                }

                pub const InputContinuation = struct {
                    value: InputFuture.ValueType = undefined,
                    state: future.State = undefined,
                    runnable: Runnable = undefined,
                    token: cancel.Token,

                    pub fn @"continue"(
                        self: *@This(),
                        value: InputFuture.ValueType,
                        state: future.State,
                    ) void {
                        self.value = value;
                        self.state = state;
                        self.runnable = .{
                            .runFn = run,
                            .ptr = self,
                        };
                        if (!self.token.isCancelled()) {
                            state.executor.submitRunnable(&self.runnable);
                        }
                    }
                };
            };
        }

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            const Result = Computation(@TypeOf(continuation));
            const InputContinuation = Result.InputContinuation;
            return .{
                .token = self.token,
                .input_computation = self.input_future.materialize(
                    InputContinuation{
                        .token = self.token,
                    },
                ),
                .next = continuation,
            };
        }

        pub fn awaitable(self: @This()) future.Impl.Awaitable(@This()) {
            return .{
                .future = self,
            };
        }
    };
}

pub fn pipe(
    self: @This(),
    f: anytype,
) Future(@TypeOf(f)) {
    return .{
        .input_future = f,
        .token = self.token,
    };
}

pub fn withCancellation(
    token: cancel.Token,
) WithCancellation {
    return .{
        .token = token,
    };
}
