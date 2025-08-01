const std = @import("std");
const assert = std.debug.assert;
const cozi = @import("../../../root.zig");
const executors = cozi.executors;
const Executor = executors.Executor;
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future.lazy;
const meta = future.meta;

const WithCancellation = @This();

cancel_ctx: *cozi.cancel.Context,

pub const CancellationError = error{
    cancelled,
};

fn makeOutputValueType(Input: type) type {
    return switch (@typeInfo(Input)) {
        .error_union => |err| (err.error_set || CancellationError)!err.payload,
        else => CancellationError!Input,
    };
}

pub fn Future(InputFuture: type) type {
    const OutputValueType = makeOutputValueType(InputFuture.ValueType);
    return struct {
        input_future: InputFuture,
        input_cancel_ctx: *cozi.cancel.Context,

        pub const ValueType = OutputValueType;

        pub fn Computation(Continuation: type) type {
            return struct {
                input_computation: InputComputation,
                next: Continuation,
                input_cancel_ctx: *cozi.cancel.Context,
                cancel_context: cozi.cancel.Context = .{},
                state: FutureState = .{},

                const Impl = @This();
                const InputComputation = InputFuture.Computation(InputContinuation);

                pub const FutureState = struct {
                    backing_field: cozi.fault.stdlike.atomic.Value(u8) = .init(0),

                    pub const State = enum(u8) {
                        started,
                        resolved,
                        cancelled,
                    };

                    const Set = std.enums.EnumSet(State);

                    pub const TransitionError = error{
                        cancelled,
                        invalid_transition,
                    };

                    pub fn set(
                        self: *@This(),
                        new_state: State,
                    ) TransitionError!Set {
                        const previous: Set = .{
                            .bits = @bitCast(@as(u3, @truncate(
                                self.backing_field
                                    .fetchOr(@intFromEnum(new_state), .seq_cst),
                            ))),
                        };
                        if (previous.contains(new_state)) {
                            return TransitionError.invalid_transition;
                        }
                        if (previous.contains(.cancelled)) {
                            return TransitionError.cancelled;
                        }
                        return previous;
                    }
                };

                pub fn start(self: *Impl) void {
                    _ = self.state.set(.started) catch |e| switch (e) {
                        error.cancelled => {
                            self.next.@"continue"(error.cancelled, .init);
                            return;
                        },
                        else => unreachable,
                    };
                    self.input_computation.start();
                }

                pub const InputContinuation = struct {
                    value: InputFuture.ValueType = undefined,
                    state: future.State = undefined,

                    pub fn @"continue"(
                        continuation: *@This(),
                        value: InputFuture.ValueType,
                        state: future.State,
                    ) void {
                        const input_computation: *InputComputation = @fieldParentPtr("next", continuation);
                        const self: *Impl = @fieldParentPtr("input_computation", input_computation);
                        self.state.set(.resolved) catch |e| switch (e) {
                            error.cancelled => {
                                return;
                            },
                            else => unreachable,
                        };
                        self.next.@"continue"(
                            value,
                            state,
                        );
                    }

                    pub fn cancel(
                        continuation: *@This(),
                        state: future.State,
                    ) void {
                        const input_computation: *InputComputation = @fieldParentPtr("next", continuation);
                        const self: *Impl = @fieldParentPtr("input_computation", input_computation);
                        const previous_state = self.state.set(.cancelled) catch unreachable;
                        if (!previous_state.contains(.resolved)) {
                            self.next.@"continue"(
                                CancellationError.cancelled,
                                state,
                            );
                        }
                    }
                };
            };
        }

        pub fn materialize(
            self: @This(),
            continuation: anytype,
            computation_storage: *Computation(@TypeOf(continuation)),
        ) void {
            const ComputationImpl = Computation(@TypeOf(continuation));
            const InputContinuation = ComputationImpl.InputContinuation;
            computation_storage.* = .{
                .next = continuation,
                .input_cancel_ctx = self.input_cancel_ctx,
                .input_computation = undefined,
            };
            self.input_future.materialize(
                InputContinuation{},
                &computation_storage.input_computation,
            );
            computation_storage.cancel_context.link(
                &computation_storage.input_computation.cancel_context,
            ) catch unreachable;
            self.input_cancel_ctx.link(
                &computation_storage.cancel_context,
            ) catch |e| switch (e) {
                // already cancelled
                error.already_cancelled => {
                    computation_storage.cancel_context.cancel();
                },
                else => unreachable,
            };
        }

        pub fn awaitable(self: @This()) future.Awaitable(@This()) {
            return .{
                .future = self,
            };
        }
    };
}

/// F<V> -> F<map(V)>
pub fn pipe(
    self: @This(),
    f: anytype,
) Future(@TypeOf(f)) {
    return .{
        .input_future = f,
        .input_cancel_ctx = self.cancel_ctx,
    };
}

pub fn withCancellation(
    cancel_ctx: *cozi.cancel.Context,
) WithCancellation {
    return .{
        .cancel_ctx = cancel_ctx,
    };
}
