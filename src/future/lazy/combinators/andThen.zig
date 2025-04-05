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
            const input_future_value_type_info = @typeInfo(InputFuture.ValueType);
            if (std.meta.activeTag(input_future_value_type_info) != .error_union) {
                @compileError(std.fmt.comptimePrint(
                    "Parameter of map function {} in {} with input future {} must be an error-union. Actual type: {}",
                    .{
                        AndThenFn,
                        @This(),
                        InputFuture,
                        InputFuture.ValueType,
                    },
                ));
            }
            const AndThenReturnFuture = meta.ReturnType(AndThenFn);
            const FlattenedType = AndThenReturnFuture.ValueType;
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
            return struct {
                input_future: InputFuture,
                map_fn: *const AndThenFn,
                map_ctx: ?*anyopaque,

                pub const ValueType = FlattenedType;

                pub const ContinuationForInputFuture = struct {
                    value: InputFuture.ValueType = undefined,
                    state: State = undefined,

                    pub fn @"continue"(
                        self: *@This(),
                        value: InputFuture.ValueType,
                        state: State,
                    ) void {
                        self.value = value;
                        self.state = state;
                    }
                };

                fn Computation(Continuation: anytype) type {
                    return struct {
                        const Self = @This();

                        const ContinuationForOutputFuture = struct {
                            value: ValueType = undefined,
                            state: State = undefined,

                            pub fn @"continue"(
                                self: *@This(),
                                value: InputFuture.ValueType,
                                state: State,
                            ) void {
                                const computation: *Self = @fieldParentPtr("output_future_continuation", self);
                                computation.next.@"continue"(value, state);
                            }
                        };

                        input_computation: InputFuture.Computation(ContinuationForInputFuture),
                        map_fn: *const AndThenFn,
                        map_ctx: ?*anyopaque,
                        next: Continuation,
                        map_runnable: Runnable = undefined,
                        output_future: AndThenReturnFuture = undefined,
                        output_future_computation: AndThenReturnFuture.Computation(*ContinuationForOutputFuture) = undefined,
                        output_future_continuation: ContinuationForOutputFuture = .{},

                        pub fn runMap(ctx_: *anyopaque) void {
                            const self: *Self = @alignCast(@ptrCast(ctx_));
                            const input_value = &self.input_computation.next.value;
                            self.output_future = @call(
                                .auto,
                                self.map_fn,
                                .{
                                    self.map_ctx,
                                    input_value.* catch unreachable,
                                },
                            );
                            self.output_future_computation = self.output_future.materialize(&self.output_future_continuation);
                            self.output_future_computation.start();
                        }

                        pub fn start(self: *@This()) void {
                            self.input_computation.start();
                            const ErrorUnion = InputFuture.ValueType;
                            const input_value: *ErrorUnion = &self.input_computation.next.value;
                            const input_state: *State = &self.input_computation.next.state;
                            if (std.meta.isError(input_value.*)) {
                                self.next.@"continue"(input_value.*, input_state.*);
                            } else {
                                self.map_runnable = .{
                                    .runFn = runMap,
                                    .ptr = self,
                                };
                                input_state.executor.submitRunnable(&self.map_runnable);
                            }
                        }
                    };
                }

                pub fn materialize(
                    self: @This(),
                    continuation: anytype,
                ) Computation(@TypeOf(continuation)) {
                    const input_computation = self.input_future.materialize(ContinuationForInputFuture{});
                    return .{
                        .input_computation = input_computation,
                        .map_fn = self.map_fn,
                        .map_ctx = self.map_ctx,
                        .next = continuation,
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

pub fn andThen(
    map_fn: anytype,
    ctx: ?*anyopaque,
) AndThen(@TypeOf(map_fn)) {
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
