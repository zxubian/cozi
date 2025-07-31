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

pub fn AndThen(
    AndThenFn: type,
    Ctx: type,
) type {
    const Args = std.meta.ArgsTuple(AndThenFn);

    return struct {
        map_fn: *const AndThenFn,
        map_ctx: Ctx,

        pub fn Future(InputFuture: type) type {
            const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
            const map_fn_has_args = args_info.fields.len > 0;
            if (!map_fn_has_args) {
                @compileError(std.fmt.comptimePrint(
                    "Map function {} in {} with input future {} must accept a parameter",
                    .{
                        AndThenFn,
                        @This(),
                        InputFuture,
                    },
                ));
            }
            const AndThenFnArgType = args_info.fields[0].type;
            const AndThenReturnFuture = meta.ReturnType(AndThenFn);
            const FlattenedType = AndThenReturnFuture.ValueType;
            const input_future_value_type_info = @typeInfo(InputFuture.ValueType);
            const input_is_error_union = comptime std.meta.activeTag(input_future_value_type_info) == .error_union;
            const UnwrappedInputType = if (input_is_error_union)
                input_future_value_type_info.error_union.payload
            else
                InputFuture.ValueType;
            comptime meta.ValidateMapFnArgs(
                InputFuture,
                AndThenReturnFuture,
                UnwrappedInputType,
                AndThenFnArgType,
                AndThenFn,
                Ctx,
            );
            if (input_is_error_union) {
                const UnwrappedValueType = input_future_value_type_info.error_union.payload;
                if (input_future_value_type_info.error_union.payload != AndThenFnArgType) {
                    @compileError(std.fmt.comptimePrint(
                        "Incompatible parameter type for map function {} in {} with input future {}. Expected: !{}. Got: !{}",
                        .{
                            AndThenFn,
                            @This(),
                            InputFuture,
                            UnwrappedValueType,
                            AndThenFnArgType,
                        },
                    ));
                }
            }
            return struct {
                input_future: InputFuture,
                map_fn: *const AndThenFn,
                map_ctx: Ctx,

                pub const ValueType = FlattenedType;

                pub fn Computation(Continuation: type) type {
                    return struct {
                        input_computation: InputComputation,
                        map_fn: *const AndThenFn,
                        map_ctx: Ctx,
                        output_future: AndThenReturnFuture = undefined,
                        output_future_computation: OutputComputation = undefined,
                        next: Continuation,

                        const ComputationImpl = @This();
                        const InputComputation = InputFuture.Computation(InputContinuation);
                        const OutputComputation = AndThenReturnFuture.Computation(OutputContinuation);

                        pub fn start(self: *@This()) void {
                            self.input_computation.start();
                        }

                        pub fn map(ctx_: *anyopaque) void {
                            const input_continuation: *InputContinuation = @alignCast(@ptrCast(ctx_));
                            const input_computation: *InputComputation = @fieldParentPtr("next", input_continuation);
                            const self: *ComputationImpl = @fieldParentPtr("input_computation", input_computation);
                            if (input_is_error_union) {
                                if (std.meta.isError(input_continuation.value)) {
                                    const error_value = blk: {
                                        _ = input_continuation.value catch |err| {
                                            break :blk err;
                                        };
                                        unreachable;
                                    };
                                    self.next.@"continue"(
                                        error_value,
                                        input_continuation.state,
                                    );
                                    return;
                                }
                            }
                            const input_value =
                                if (input_is_error_union)
                                    input_continuation.value catch unreachable
                                else
                                    input_continuation.value;
                            const and_then_fn_args: std.meta.ArgsTuple(AndThenFn) = blk: {
                                var tmp_args: std.meta.ArgsTuple(AndThenFn) = undefined;
                                comptime var i: usize = 0;
                                tmp_args[i] = input_value;
                                i += 1;
                                inline for (self.map_ctx) |ctx_arg| {
                                    tmp_args[i] = ctx_arg;
                                    i += 1;
                                }
                                break :blk tmp_args;
                            };
                            self.output_future = @call(
                                .auto,
                                self.map_fn,
                                and_then_fn_args,
                            );
                            self.output_future
                                .materialize(
                                OutputContinuation{},
                                &self.output_future_computation,
                            );
                            self.output_future_computation.start();
                        }

                        pub const InputContinuation = struct {
                            value: InputFuture.ValueType = undefined,
                            state: State = undefined,
                            map_runnable: Runnable = undefined,

                            pub fn @"continue"(
                                self: *@This(),
                                value: InputFuture.ValueType,
                                state: State,
                            ) void {
                                self.value = value;
                                self.state = state;
                                self.map_runnable = .{
                                    .runFn = map,
                                    .ptr = self,
                                };
                                state.executor.submitRunnable(&self.map_runnable);
                            }
                        };

                        pub fn runOuter(ctx_: *anyopaque) void {
                            const output_continuation: *OutputContinuation = @alignCast(@ptrCast(ctx_));
                            const output_computation: *OutputComputation = @fieldParentPtr("next", output_continuation);
                            const self: *ComputationImpl = @fieldParentPtr("output_future_computation", output_computation);
                            self.next.@"continue"(output_continuation.value, output_continuation.state);
                        }

                        const OutputContinuation = struct {
                            value: ValueType = undefined,
                            state: State = undefined,
                            runnable: Runnable = undefined,

                            pub fn @"continue"(
                                self: *@This(),
                                value: FlattenedType,
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
                    };
                }

                pub fn materialize(
                    self: @This(),
                    continuation: anytype,
                    computation_storage: *Computation(@TypeOf(continuation)),
                ) void {
                    const Result = Computation(@TypeOf(continuation));
                    const InputContinuation = Result.InputContinuation;
                    computation_storage.* = .{
                        .input_computation = undefined,
                        .map_fn = self.map_fn,
                        .map_ctx = self.map_ctx,
                        .next = continuation,
                    };
                    self.input_future.materialize(
                        InputContinuation{},
                        &computation_storage.input_computation,
                    );
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
                .map_fn = self.map_fn,
                .map_ctx = self.map_ctx,
            };
        }
    };
}

/// This Future applies map_fn to the result of its piped input,
/// but only if the result is not an Error.
/// * Future<E!T> -> F<E!map_fn(ctx, T)>
///
/// `map_fn` is executed on the last Executor set earlier in the pipeline.
pub fn andThen(
    map_fn: anytype,
    ctx: anytype,
) AndThen(
    @TypeOf(map_fn),
    @TypeOf(ctx),
) {
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
