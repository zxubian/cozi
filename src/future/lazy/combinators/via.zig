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
                input_computation: InputFuture.Computation(InputContinuation),
                next: Continuation,
                next_executor: Executor,

                const Impl = @This();

                pub fn init(self: *@This()) void {
                    self.input_computation.init();
                }

                pub fn start(self: *@This()) void {
                    self.input_computation.start();
                }

                pub fn run(ctx: *anyopaque) void {
                    const input_continuation: *InputContinuation = @alignCast(@ptrCast(ctx));
                    const input_computation: *InputFuture.Computation(InputContinuation) = @fieldParentPtr(
                        "next",
                        input_continuation,
                    );
                    const self: *Impl = @fieldParentPtr(
                        "input_computation",
                        input_computation,
                    );
                    self.next.@"continue"(
                        input_continuation.value,
                        .{
                            .executor = self.next_executor,
                        },
                    );
                }

                pub const InputContinuation = struct {
                    runnable: Runnable = undefined,
                    value: InputFuture.ValueType = undefined,

                    pub fn init(_: *@This()) void {}

                    pub fn @"continue"(
                        self: *@This(),
                        value: InputFuture.ValueType,
                        state: State,
                    ) void {
                        self.value = value;
                        self.runnable = Runnable{
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
                .input_computation = self.input_future.materialize(
                    InputContinuation{},
                ),
                .next_executor = self.next_executor,
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
    self: *const Via,
    f: anytype,
) Future(@TypeOf(f)) {
    return .{
        .input_future = f,
        .next_executor = self.next_executor,
    };
}

/// Sets the `Executor` for Futures succeeding in the pipeline.
/// * Future<Value> -> Future<Value>
///
/// Forwards the resolved value of the previous Future as-is.
/// Cannot be the first Future in a pipeline (must follow some other Future).
pub fn via(executor: Executor) Via {
    return .{
        .next_executor = executor,
    };
}
