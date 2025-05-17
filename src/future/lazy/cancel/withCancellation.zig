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

cancel_token: cancel.Token,

pub fn Future(InputFuture: type) type {
    return struct {
        input_future: InputFuture,
        cancel_token: cancel.Token,

        pub const ValueType = cancel.CancellationError!InputFuture.ValueType;

        pub fn Computation(Continuation: type) type {
            return struct {
                runnable: Runnable = undefined,
                cancel_state: future.cancellation.State = .{},
                cancel_ctx: future.cancellation.LinkedContext = undefined,
                on_outside_cancel: future.cancellation.Callback = undefined,

                outside_cancel_token: future.cancellation.Token,
                input_computation: InputComputation,
                next: Continuation,

                const State = enum {
                    init,
                    resolved,
                    cancelled,
                };

                const Impl = @This();
                const InputComputation = InputFuture.Computation(InputContinuation);

                pub fn init(self: *Impl) void {
                    self.input_computation.init();

                    self.on_outside_cancel = .{
                        .runnable = .{
                            .runFn = @ptrCast(&future.cancellation.State.cancel),
                            .ptr = &self.cancel_state,
                        },
                    };
                    self.outside_cancel_token.subscribe(&self.on_outside_cancel);
                    self.cancel_ctx.init(self, &self.cancel_state);

                    self.next.init();
                    self.cancel_ctx.linkTo(self.next.cancel_ctx);
                }

                pub fn start(self: *Impl) void {
                    if (self.cancel_ctx.isCanceled()) {
                        return;
                    }
                    self.input_computation.start();
                }

                pub fn run(ctx_: *anyopaque) void {
                    const input_continuation: *InputContinuation = @alignCast(@ptrCast(ctx_));
                    const input_computation: *InputComputation = @fieldParentPtr(
                        "next",
                        input_continuation,
                    );
                    const self: *Impl = @fieldParentPtr(
                        "input_computation",
                        input_computation,
                    );
                    if (self.cancel_ctx.isCanceled()) {
                        return;
                    }
                    self.next.@"continue"(
                        input_continuation.value,
                        input_continuation.state,
                    );
                }

                pub fn onCancel(self: *@This()) void {
                    self.next.@"continue"(
                        cancel.CancellationError.canceled,
                        .init,
                    );
                }

                pub fn getCancelState(self: *Impl) *future.cancellation.State {
                    return &self.cancel_state;
                }

                pub const InputContinuation = struct {
                    value: InputFuture.ValueType = undefined,
                    state: future.State = undefined,
                    runnable: Runnable = undefined,
                    cancel_ctx: future.cancellation.Context,

                    pub fn @"continue"(
                        self: *@This(),
                        value: InputFuture.ValueType,
                        state: future.State,
                    ) void {
                        const input_computation: *InputComputation = @fieldParentPtr(
                            "next",
                            self,
                        );
                        const parent: *Impl = @fieldParentPtr(
                            "input_computation",
                            input_computation,
                        );
                        if (parent.cancel_ctx.isCanceled()) {
                            return;
                        }
                        self.value = value;
                        self.state = state;
                        self.runnable = .{
                            .runFn = run,
                            .ptr = self,
                        };
                        state.executor.submitRunnable(&self.runnable);
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
                .outside_cancel_token = self.cancel_token,
                .input_computation = self.input_future.materialize(
                    InputContinuation{},
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
        .cancel_token = self.cancel_token,
    };
}

pub fn withCancellation(
    cancel_token: cancel.Token,
) WithCancellation {
    return .{
        .cancel_token = cancel_token,
    };
}
