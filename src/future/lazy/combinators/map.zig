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
            const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
            const map_fn_has_args = args_info.fields.len > 1;
            // TODO: make this more flexible?
            assert(args_info.fields[0].type == ?*anyopaque);
            if (map_fn_has_args) {
                assert(args_info.fields[1].type == InputFuture.ValueType);
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

                fn Computation(Continuation: anytype) type {
                    return struct {
                        input_computation: InputFuture.Computation(ContinuationForInputFuture),
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
                                    if (map_fn_has_args) {
                                        ctx.output.* = @call(
                                            .auto,
                                            ctx.map_fn,
                                            .{ ctx.map_ctx, ctx.input.* },
                                        );
                                    } else {
                                        ctx.output.* = @call(
                                            .auto,
                                            ctx.map_fn,
                                            .{ctx.map_ctx},
                                        );
                                    }
                                    ctx.wait_group.finish();
                                }
                            };
                            self.input_computation.start();
                            const input_value: *InputFuture.ValueType = &self.input_computation.next.value;
                            const input_state: *State = &self.input_computation.next.state;
                            var output: OutputValueType = undefined;
                            var ctx: Ctx = .{
                                .input = input_value,
                                .output = &output,
                                .map_fn = self.map_fn,
                                .map_ctx = self.map_ctx,
                            };
                            ctx.wait_group.startMany(2);
                            var runnable: Runnable = .{
                                .runFn = Ctx.run,
                                .ptr = &ctx,
                            };
                            input_state.executor.submitRunnable(&runnable);
                            ctx.wait_group.finish();
                            ctx.wait_group.wait();
                            self.next.@"continue"(output, input_state.*);
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
