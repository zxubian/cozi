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

const Flatten = @This();

pub fn Future(InputFuture: type) type {
    const OuterFuture = InputFuture;
    const InnerFuture = InputFuture.ValueType;
    const FlattenedValue = InnerFuture.ValueType;
    return struct {
        outer_future: OuterFuture,
        pub const ValueType = FlattenedValue;

        pub fn Computation(Continuation: type) type {
            return struct {
                outer_computation: OuterComputation,
                inner_computation: InnerComputation = undefined,
                next: Continuation,

                const Impl = @This();
                const OuterComputation = OuterFuture.Computation(OuterFutureContinuation);
                const InnerComputation = InnerFuture.Computation(InnerFutureContinuation);

                pub fn start(self: *@This()) void {
                    self.outer_computation.start();
                }

                fn runOuter(ctx: *anyopaque) void {
                    const outer_continuation: *OuterFutureContinuation = @alignCast(@ptrCast(ctx));
                    const outer_computation: *OuterComputation = @fieldParentPtr("next", outer_continuation);
                    const self: *Impl = @fieldParentPtr("outer_computation", outer_computation);
                    const inner_future = &outer_continuation.value;
                    self.inner_computation = inner_future.materialize(
                        InnerFutureContinuation{},
                    );
                    self.inner_computation.start();
                }

                fn runInner(ctx: *anyopaque) void {
                    const inner_continuation: *InnerFutureContinuation = @alignCast(@ptrCast(ctx));
                    const inner_computation: *InnerComputation = @fieldParentPtr("next", inner_continuation);
                    const self: *Impl = @fieldParentPtr("inner_computation", inner_computation);
                    self.next.@"continue"(inner_continuation.value, inner_continuation.state);
                }

                pub const OuterFutureContinuation = struct {
                    value: InnerFuture = undefined,
                    state: State = undefined,
                    runnable: Runnable = undefined,

                    pub fn @"continue"(
                        self: *@This(),
                        value: InnerFuture,
                        state: State,
                    ) void {
                        self.value = value;
                        self.state = state;
                        self.runnable = .{
                            .runFn = runOuter,
                            .ptr = self,
                        };
                        state.executor.submitRunnable(&self.runnable);
                    }
                };

                pub const InnerFutureContinuation = struct {
                    value: FlattenedValue = undefined,
                    state: State = undefined,
                    runnable: Runnable = undefined,

                    pub fn @"continue"(
                        self: *@This(),
                        value: FlattenedValue,
                        state: State,
                    ) void {
                        self.value = value;
                        self.state = state;
                        self.runnable = .{
                            .runFn = runInner,
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
            const InputContinuation = Result.OuterFutureContinuation;
            return .{
                .outer_computation = self.outer_future.materialize(
                    InputContinuation{},
                ),
                .next = continuation,
            };
        }
    };
}

pub fn pipe(
    _: @This(),
    f: anytype,
) Future(@TypeOf(f)) {
    return .{
        .outer_future = f,
    };
}

/// Future<Future<T>> -> Future<T>
pub fn flatten() Flatten {
    return .{};
}
