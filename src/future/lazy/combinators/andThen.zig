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

pub fn AndThen(AndThenFn: type) type {
    const Args = std.meta.ArgsTuple(AndThenFn);

    return struct {
        map_fn: *const AndThenFn,
        map_ctx: ?*anyopaque,

        pub fn Future(InputFuture: type) type {
            const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
            const map_fn_has_args = args_info.fields.len > 1;
            // TODO: make this more flexible?
            assert(args_info.fields[0].type == ?*anyopaque);
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
            const AndThenFnArgType = args_info.fields[1].type;
            const AndThenReturnFuture = meta.ReturnType(AndThenFn);
            const FlattenedType = AndThenReturnFuture.ValueType;
            const input_future_value_type_info = @typeInfo(InputFuture.ValueType);
            const input_is_error_union = comptime std.meta.activeTag(input_future_value_type_info) == .error_union;
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
                map_ctx: ?*anyopaque,

                pub const ValueType = FlattenedType;

                pub fn Computation(Continuation: type) type {
                    return struct {
                        input_computation: InputFuture.Computation(ContinuationForInputFuture),

                        pub const ContinuationForInputFuture = struct {
                            value: InputFuture.ValueType = undefined,
                            state: State = undefined,
                            map_runnable: Runnable = undefined,
                            output_future: AndThenReturnFuture = undefined,
                            output_future_computation: AndThenReturnFuture.Computation(*ContinuationForOutputFuture) = undefined,
                            output_future_continuation: ContinuationForOutputFuture = .{},
                            map_fn: *const AndThenFn,
                            map_ctx: ?*anyopaque,
                            next: Continuation,

                            const ContinuationForOutputFuture = struct {
                                value: ValueType = undefined,
                                state: State = undefined,

                                pub fn @"continue"(
                                    self: *@This(),
                                    value: FlattenedType,
                                    state: State,
                                ) void {
                                    const computation: *ContinuationForInputFuture = @fieldParentPtr("output_future_continuation", self);
                                    computation.next.@"continue"(value, state);
                                }
                            };

                            pub fn @"continue"(
                                self: *@This(),
                                value: InputFuture.ValueType,
                                state: State,
                            ) void {
                                self.value = value;
                                self.state = state;
                                if (input_is_error_union) {
                                    if (std.meta.isError(value)) {
                                        self.next.@"continue"(value, state);
                                    } else {
                                        self.map_runnable = .{
                                            .runFn = runMap,
                                            .ptr = self,
                                        };
                                        state.executor.submitRunnable(&self.map_runnable);
                                    }
                                } else {
                                    self.map_runnable = .{
                                        .runFn = runMap,
                                        .ptr = self,
                                    };
                                    state.executor.submitRunnable(&self.map_runnable);
                                }
                            }
                        };

                        pub fn runMap(ctx_: *anyopaque) void {
                            const self: *ContinuationForInputFuture = @alignCast(@ptrCast(ctx_));
                            const input_value =
                                if (input_is_error_union)
                                    self.value catch unreachable
                                else
                                    self.value;
                            self.output_future = @call(
                                .auto,
                                self.map_fn,
                                .{
                                    self.map_ctx,
                                    input_value,
                                },
                            );
                            self.output_future_computation = self.output_future.materialize(
                                &self.output_future_continuation,
                            );
                            self.output_future_computation.start();
                        }

                        pub fn start(self: *@This()) void {
                            self.input_computation.start();
                        }
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
                                .map_fn = self.map_fn,
                                .map_ctx = self.map_ctx,
                                .next = continuation,
                            },
                        ),
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
/// Future<E!T> -> F<E!map_fn(T)>
/// `map_fn` is executed on the Executor set earlier in the pipeline.
pub fn andThen(
    map_fn: anytype,
    ctx: ?*anyopaque,
) AndThen(@TypeOf(map_fn)) {
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
