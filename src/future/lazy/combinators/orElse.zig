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

pub fn OrElse(OrElseFn: type) type {
    const Args = std.meta.ArgsTuple(OrElseFn);

    return struct {
        map_fn: *const OrElseFn,
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
                        OrElseFn,
                        @This(),
                        InputFuture,
                    },
                ));
            }
            const OrElseFnArgType = args_info.fields[1].type;
            const input_future_value_type_info = @typeInfo(InputFuture.ValueType);
            if (std.meta.activeTag(input_future_value_type_info) != .error_union) {
                @compileError(std.fmt.comptimePrint(
                    "Parameter of map function {} in {} with input future {} must be an error-union. Actual type: {}",
                    .{
                        OrElseFn,
                        @This(),
                        InputFuture,
                        InputFuture.ValueType,
                    },
                ));
            }
            const OrElseReturnFuture = meta.ReturnType(OrElseFn);
            const FlattenedType = OrElseReturnFuture.ValueType;
            const UnwrappedValueType = input_future_value_type_info.error_union.payload;
            const Error = input_future_value_type_info.error_union.error_set;
            if (Error != OrElseFnArgType) {
                @compileError(std.fmt.comptimePrint(
                    "Incompatible parameter type for map function {} in {} with input future {}. Expected: !{}. Got: !{}",
                    .{
                        OrElseFn,
                        @This(),
                        InputFuture,
                        UnwrappedValueType,
                        OrElseFnArgType,
                    },
                ));
            }
            return struct {
                input_future: InputFuture,
                map_fn: *const OrElseFn,
                map_ctx: ?*anyopaque,

                pub const ValueType = FlattenedType;

                pub fn Computation(Continuation: type) type {
                    return struct {
                        input_computation: InputFuture.Computation(ContinuationForInputFuture),

                        pub fn start(self: *@This()) void {
                            self.input_computation.start();
                        }

                        pub const ContinuationForInputFuture = struct {
                            value: InputFuture.ValueType = undefined,
                            state: State = undefined,
                            map_fn: *const OrElseFn,
                            map_ctx: ?*anyopaque,
                            next: Continuation,
                            map_runnable: Runnable = undefined,
                            output_future: OrElseReturnFuture = undefined,
                            output_future_computation: OrElseReturnFuture.Computation(*ContinuationForOutputFuture) = undefined,
                            output_future_continuation: ContinuationForOutputFuture = .{},

                            pub fn @"continue"(
                                self: *@This(),
                                value: InputFuture.ValueType,
                                state: State,
                            ) void {
                                self.value = value;
                                self.state = state;
                                if (std.meta.isError(value)) {
                                    self.map_runnable = .{
                                        .runFn = runMap,
                                        .ptr = self,
                                    };
                                    state.executor.submitRunnable(&self.map_runnable);
                                } else {
                                    self.next.@"continue"(value catch unreachable, state);
                                }
                            }

                            pub fn runMap(ctx_: *anyopaque) void {
                                const self: *@This() = @alignCast(@ptrCast(ctx_));
                                const input_value = &self.value;
                                const error_value = blk: {
                                    _ = input_value.* catch |err| {
                                        break :blk err;
                                    };
                                    unreachable;
                                };
                                self.output_future = @call(
                                    .auto,
                                    self.map_fn,
                                    .{ self.map_ctx, error_value },
                                );
                                self.output_future_computation = self.output_future.materialize(&self.output_future_continuation);
                                self.output_future_computation.start();
                            }

                            const ContinuationForOutputFuture = struct {
                                value: ValueType = undefined,
                                state: State = undefined,

                                pub fn @"continue"(
                                    self: *@This(),
                                    value: FlattenedType,
                                    state: State,
                                ) void {
                                    const computation: *ContinuationForInputFuture = @fieldParentPtr(
                                        "output_future_continuation",
                                        self,
                                    );
                                    computation.next.@"continue"(value, state);
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

        /// F<V> -> F<map(V)>
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

pub fn orElse(
    map_fn: anytype,
    ctx: ?*anyopaque,
) OrElse(@TypeOf(map_fn)) {
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
