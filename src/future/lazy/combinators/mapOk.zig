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

pub fn MapOk(MapOkFn: type) type {
    const Args = std.meta.ArgsTuple(MapOkFn);

    return struct {
        map_fn: *const MapOkFn,
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
                        MapOkFn,
                        @This(),
                        InputFuture,
                    },
                ));
            }
            const MapOkFnArgType = args_info.fields[1].type;
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
            const UnwrappedValueType = input_future_value_type_info.error_union.payload;
            if (input_future_value_type_info.error_union.payload != MapOkFnArgType) {
                @compileError(std.fmt.comptimePrint(
                    "Incompatible parameter type for map function {} in {} with input future {}. Expected: !{}. Got: !{}",
                    .{
                        MapOkFn,
                        @This(),
                        InputFuture,
                        UnwrappedValueType,
                        MapOkFnArgType,
                    },
                ));
            }
            return struct {
                input_future: InputFuture,
                map_fn: *const MapOkFn,
                map_ctx: ?*anyopaque,

                pub const ValueType = OutputValueType;

                pub fn Computation(Continuation: anytype) type {
                    return struct {
                        input_computation: InputFuture.Computation(ContinuationForInputFuture),

                        const Self = @This();

                        pub const ContinuationForInputFuture = struct {
                            value: InputFuture.ValueType = undefined,
                            state: State = undefined,
                            runnable: Runnable = undefined,
                            map_fn: *const MapOkFn,
                            map_ctx: ?*anyopaque,
                            next: Continuation,

                            pub fn @"continue"(
                                self: *@This(),
                                value: InputFuture.ValueType,
                                state: State,
                            ) void {
                                self.value = value;
                                self.state = state;
                                if (std.meta.isError(value)) {
                                    self.next.@"continue"(value, state);
                                } else {
                                    self.runnable = .{
                                        .runFn = run,
                                        .ptr = self,
                                    };
                                    state.executor.submitRunnable(&self.runnable);
                                }
                            }
                        };

                        pub fn run(ctx_: *anyopaque) void {
                            const self: *ContinuationForInputFuture = @alignCast(@ptrCast(ctx_));
                            const input_value = &self.value;
                            const output: OutputValueType = blk: {
                                if (map_fn_has_args) {
                                    break :blk @call(
                                        .auto,
                                        self.map_fn,
                                        .{
                                            self.map_ctx,
                                            input_value.* catch unreachable,
                                        },
                                    );
                                } else {
                                    break :blk @call(
                                        .auto,
                                        self.map_fn,
                                        .{self.map_ctx},
                                    );
                                }
                            };
                            self.next.@"continue"(output, self.state);
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

pub fn mapOk(
    map_fn: anytype,
    ctx: ?*anyopaque,
) MapOk(@TypeOf(map_fn)) {
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
