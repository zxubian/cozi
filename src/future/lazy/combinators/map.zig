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

pub fn Map(MapFn: type) type {
    const Args = std.meta.ArgsTuple(MapFn);
    const OutputValueType = meta.ReturnType(MapFn);

    return struct {
        map_fn: *const MapFn,
        map_ctx: ?*anyopaque,

        pub fn Future(InputFuture: type) type {
            const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
            const map_fn_has_args = args_info.fields.len > 1;
            // TODO: make this more flexible?
            assert(args_info.fields[0].type == ?*anyopaque);
            if (map_fn_has_args) {
                const MapFnArgType = args_info.fields[1].type;
                if (InputFuture.ValueType != MapFnArgType) {
                    @compileError(std.fmt.comptimePrint(
                        "Incorrect parameter type for map function {} in {} with input future {}. Expected: {}. Got: {}",
                        .{
                            MapFn,
                            @This(),
                            InputFuture,
                            InputFuture.ValueType,
                            MapFnArgType,
                        },
                    ));
                }
            }
            return struct {
                input_future: InputFuture,
                map_fn: *const MapFn,
                map_ctx: ?*anyopaque,

                pub const ValueType = OutputValueType;

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

                pub fn Computation(Continuation: anytype) type {
                    return struct {
                        input_computation: InputFuture.Computation(ContinuationForInputFuture),
                        map_fn: *const MapFn,
                        map_ctx: ?*anyopaque,
                        next: Continuation,
                        runnable: Runnable = undefined,
                        const Self = @This();

                        pub fn run(ctx_: *anyopaque) void {
                            const self: *Self = @alignCast(@ptrCast(ctx_));
                            const input_value = &self.input_computation.next.value;
                            const output: OutputValueType = blk: {
                                if (map_fn_has_args) {
                                    break :blk @call(
                                        .auto,
                                        self.map_fn,
                                        .{
                                            self.map_ctx,
                                            input_value.*,
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
                            self.next.@"continue"(output, self.input_computation.next.state);
                        }

                        pub fn start(self: *@This()) void {
                            self.input_computation.start();
                            const input_state: *State = &self.input_computation.next.state;
                            self.runnable = .{
                                .runFn = run,
                                .ptr = self,
                            };
                            input_state.executor.submitRunnable(&self.runnable);
                        }
                    };
                }

                pub fn materialize(
                    self: @This(),
                    continuation_ptr: anytype,
                ) Computation(@TypeOf(continuation_ptr)) {
                    const input_computation = self.input_future.materialize(ContinuationForInputFuture{});
                    return .{
                        .input_computation = input_computation,
                        .map_fn = self.map_fn,
                        .map_ctx = self.map_ctx,
                        .next = continuation_ptr,
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

pub fn map(
    map_fn: anytype,
    ctx: ?*anyopaque,
) Map(@TypeOf(map_fn)) {
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
