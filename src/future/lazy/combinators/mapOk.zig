const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../root.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../root.zig").core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
const State = future.State;
const meta = future.meta;

pub fn MapOk(
    MapOkFn: type,
    Ctx: type,
) type {
    const Args = std.meta.ArgsTuple(MapOkFn);

    return struct {
        map_fn: *const MapOkFn,
        map_ctx: Ctx,

        pub fn Future(InputFuture: type) type {
            const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
            const input_future_value_type_info = @typeInfo(InputFuture.ValueType);
            if (std.meta.activeTag(input_future_value_type_info) != .error_union) {
                @compileError(std.fmt.comptimePrint(
                    "Parameter of map function {} in {} with input future {} must be an error-union. Actual type: {}",
                    .{
                        MapOkFn,
                        @This(),
                        InputFuture,
                        InputFuture.ValueType,
                    },
                ));
            }
            const MapOutput = meta.ReturnType(MapOkFn);
            const OutputErrorSet: type = comptime blk: {
                const InputErrorSet = input_future_value_type_info.error_union.error_set;
                break :blk switch (@typeInfo(MapOutput)) {
                    .error_union => |map_output_error_info| map_output_error_info.error_set || InputErrorSet,
                    else => InputErrorSet,
                };
            };
            const OutputPayload: type = switch (@typeInfo(MapOutput)) {
                .error_union => |map_output_error_info| map_output_error_info.payload,
                else => MapOutput,
            };
            const output_value_type: std.builtin.Type = .{
                .error_union = .{
                    .error_set = OutputErrorSet,
                    .payload = OutputPayload,
                },
            };
            const OutputValueType = @Type(output_value_type);
            const MapOkFnArgType = args_info.fields[0].type;
            const UnwrappedValueType = input_future_value_type_info.error_union.payload;
            comptime meta.ValidateMapFnArgs(
                InputFuture,
                OutputValueType,
                UnwrappedValueType,
                MapOkFnArgType,
                MapOkFn,
                Ctx,
            );
            return struct {
                input_future: InputFuture,
                map_fn: *const MapOkFn,
                map_ctx: Ctx,

                pub const ValueType = OutputValueType;

                pub fn Computation(Continuation: type) type {
                    return struct {
                        input_computation: InputComputation,
                        map_fn: *const MapOkFn,
                        map_ctx: Ctx,
                        next: Continuation,

                        const ComputationImpl = @This();
                        const InputComputation = InputFuture.Computation(InputContinuation);

                        pub const InputContinuation = struct {
                            value: InputFuture.ValueType = undefined,
                            state: State = undefined,
                            runnable: Runnable = undefined,

                            pub fn @"continue"(
                                self: *@This(),
                                value: InputFuture.ValueType,
                                state: State,
                            ) void {
                                self.value = value;
                                self.state = state;
                                self.runnable = .{
                                    .runFn = run,
                                    .ptr = self,
                                };
                                state.executor.submitRunnable(&self.runnable);
                            }
                        };

                        pub fn run(ctx_: *anyopaque) void {
                            const input_continuation: *InputContinuation = @alignCast(@ptrCast(ctx_));
                            const input_computation: *InputComputation = @fieldParentPtr("next", input_continuation);
                            const self: *ComputationImpl = @fieldParentPtr("input_computation", input_computation);
                            if (std.meta.isError(input_continuation.value)) {
                                self.next.@"continue"(
                                    input_continuation.value,
                                    input_continuation.state,
                                );
                                return;
                            }
                            const input_value = &input_continuation.value;
                            const map_ok_fn_args: std.meta.ArgsTuple(MapOkFn) = blk: {
                                var tmp_args: std.meta.ArgsTuple(MapOkFn) = undefined;
                                comptime var i: usize = 0;
                                tmp_args[i] = input_value.* catch unreachable;
                                i += 1;
                                inline for (self.map_ctx) |ctx_arg| {
                                    tmp_args[i] = ctx_arg;
                                    i += 1;
                                }
                                break :blk tmp_args;
                            };
                            const output: OutputValueType = @call(
                                .auto,
                                self.map_fn,
                                map_ok_fn_args,
                            );
                            self.next.@"continue"(
                                output,
                                input_continuation.state,
                            );
                        }

                        pub fn start(self: *@This()) void {
                            self.input_computation.start();
                        }
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
/// * Future<V> -> F<map(V)>
///
/// map_fn is executed on the Executor set earlier in the pipeline.
pub fn mapOk(
    map_fn: anytype,
    ctx: anytype,
) MapOk(@TypeOf(map_fn), @TypeOf(ctx)) {
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
