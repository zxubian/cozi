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

fn Map(MapFn: type) type {
    const Args = std.meta.ArgsTuple(MapFn);
    const OutputValueType = meta.ReturnType(MapFn);

    return struct {
        map_fn: *const MapFn,
        map_ctx: ?*anyopaque,

        fn MapFuture(InputFuture: type) type {
            comptime {
                const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
                // TODO: make this more flexible?
                assert(args_info.fields[0].type == ?*anyopaque);
                assert(args_info.fields[1].type == InputFuture.ValueType);
            }
            return struct {
                input_future: InputFuture,
                map_fn: *const MapFn,
                map_ctx: ?*anyopaque,

                pub const ValueType = OutputValueType;

                pub const ContinuationForInputFuture = struct {
                    input_value: InputFuture.ValueType = undefined,
                    input_state: State = undefined,
                    pub fn @"continue"(
                        self: *@This(),
                        value: InputFuture.ValueType,
                        state: State,
                    ) void {
                        self.input_value = value;
                        self.input_state = state;
                    }
                };

                fn Computation(Continuation: anytype) type {
                    return struct {
                        input: InputFuture.ValueType,
                        output: OutputValueType,
                        state: State,
                        map_fn: *const MapFn,
                        map_ctx: ?*anyopaque,
                        next: Continuation,

                        pub fn start(self: *@This()) void {
                            const Ctx = struct {
                                input: *InputFuture.ValueType,
                                output: *OutputValueType,
                                map_fn: *const MapFn,
                                map_ctx: ?*anyopaque,
                                wait_group: std.Thread.WaitGroup = .{},
                                pub fn run(ctx_: *anyopaque) void {
                                    const ctx: *@This() = @alignCast(@ptrCast(ctx_));
                                    ctx.output.* = @call(
                                        .auto,
                                        ctx.map_fn,
                                        .{ ctx.map_ctx, ctx.input.* },
                                    );
                                    ctx.wait_group.finish();
                                }
                            };
                            var ctx: Ctx = .{
                                .input = &self.input,
                                .output = &self.output,
                                .map_fn = self.map_fn,
                                .map_ctx = self.map_ctx,
                            };
                            ctx.wait_group.startMany(2);
                            var runnable: Runnable = .{
                                .runFn = Ctx.run,
                                .ptr = &ctx,
                            };
                            self.state.executor.submitRunnable(&runnable);
                            ctx.wait_group.finish();
                            ctx.wait_group.wait();
                            self.next.@"continue"(
                                self.output,
                                self.state,
                            );
                        }

                        pub fn makeRunnable(self: *@This()) Runnable {
                            return Runnable{
                                .runFn = @This().run,
                                .ptr = self,
                            };
                        }
                    };
                }

                pub fn materialize(
                    self: @This(),
                    continuation: anytype,
                ) Computation(@TypeOf(continuation)) {
                    var input_future_result: ContinuationForInputFuture = .{};
                    var input_computation = self.input_future.materialize(&input_future_result);
                    input_computation.start();
                    return .{
                        .input = input_future_result.input_value,
                        .output = undefined,
                        .state = input_future_result.input_state,
                        .map_fn = self.map_fn,
                        .map_ctx = self.map_ctx,
                        .next = continuation,
                    };
                }
            };
        }

        /// F<V> -> F<V>
        pub fn pipe(
            self: @This(),
            f: anytype,
        ) MapFuture(@TypeOf(f)) {
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
