const std = @import("std");
const assert = std.debug.assert;
const cozi = @import("../../../root.zig");
const executors = cozi.executors;
const Executor = executors.Executor;
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future.lazy;
const State = future.State;
const meta = future.meta;

pub fn Map(MapFn: type, Ctx: type) type {
    const OutputValueType = meta.ReturnType(MapFn);

    return struct {
        map_fn: *const MapFn,
        map_ctx: Ctx,

        pub fn ValidateMapFnArgs(InputFuture: type) void {
            const params_count = blk: {
                var count = std.meta.fields(Ctx).len + 1;
                if (InputFuture.ValueType != void) {
                    count += 1;
                }
                break :blk count;
            };
            var params: [params_count]std.builtin.Type.Fn.Param = undefined;
            comptime var offset: usize = 0;
            if (InputFuture.ValueType != void) {
                params[offset] =
                    .{
                        .is_generic = false,
                        .is_noalias = false,
                        .type = InputFuture.ValueType,
                    };
                offset += 1;
            }
            for (std.meta.fields(Ctx), 0..) |field, field_idx| {
                params[field_idx + offset] = .{
                    .is_generic = false,
                    .is_noalias = false,
                    .type = field.type,
                };
            }
            params[params_count - 1] = .{
                .is_generic = false,
                .is_noalias = false,
                .type = future.cancel.Token,
            };
            const expected_signature_info: std.builtin.Type = .{ .@"fn" = .{
                .calling_convention = .auto,
                .is_generic = false,
                .is_var_args = false,
                .return_type = OutputValueType,
                .params = &params,
            } };
            const expected_signature = @Type(expected_signature_info);
            const actual = std.meta.fields(std.meta.ArgsTuple(MapFn));
            if (actual.len != params.len) {
                @compileError(
                    std.fmt.comptimePrint(
                        "Incorrect function signature.\nExpected:\n{}\nGot:\n{}",
                        .{ expected_signature, MapFn },
                    ),
                );
            }
            inline for (actual, params) |arg, expected| {
                if (arg.type != expected.type) {
                    @compileError(
                        std.fmt.comptimePrint(
                            "Incorrect function signature.\nExpected:\n{}\nGot:\n{}",
                            .{ expected_signature, MapFn },
                        ),
                    );
                }
            }
        }

        pub fn Future(InputFuture: type) type {
            comptime ValidateMapFnArgs(InputFuture);
            const input_future_produces_value = InputFuture.ValueType != void;
            return struct {
                input_future: InputFuture,
                map_fn: *const MapFn,
                map_ctx: Ctx,

                pub const ValueType = OutputValueType;

                pub fn Computation(Continuation: type) type {
                    return struct {
                        input_computation: InputComputation,
                        map_fn: *const MapFn,
                        map_ctx: Ctx,
                        runnable: Runnable = undefined,
                        next: Continuation,

                        const Impl = @This();
                        const InputComputation = InputFuture.Computation(InputContinuation);

                        pub fn init(self: *Impl) void {
                            self.input_computation.init();
                            self.next.init();
                        }

                        pub fn start(self: *Impl) void {
                            self.input_computation.start();
                        }

                        pub fn run(ctx_: *anyopaque) void {
                            const input_continuation: *InputContinuation = @alignCast(@ptrCast(ctx_));
                            const input_computation: *InputComputation = @fieldParentPtr("next", input_continuation);
                            const self: *Impl = @fieldParentPtr("input_computation", input_computation);
                            const map_fn_args = blk: {
                                var res: std.meta.ArgsTuple(MapFn) = undefined;
                                comptime var i: usize = 0;
                                if (input_future_produces_value) {
                                    res[i] = input_continuation.value;
                                    i += 1;
                                }
                                inline for (self.map_ctx) |ctx_arg| {
                                    res[i] = ctx_arg;
                                    i += 1;
                                }
                                res[i] = undefined;
                                break :blk res;
                            };
                            const output: OutputValueType = @call(
                                .auto,
                                self.map_fn,
                                map_fn_args,
                            );
                            self.next.@"continue"(
                                output,
                                input_continuation.state,
                            );
                        }

                        pub const InputContinuation = struct {
                            value: InputFuture.ValueType = undefined,
                            state: State = undefined,
                            runnable: Runnable = undefined,

                            pub fn init(_: *@This()) void {}

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
                        .map_fn = self.map_fn,
                        .map_ctx = self.map_ctx,
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

/// This Future applies map_fn to the result of its piped input.
/// * Future<T> -> Future<map_fn(T)>
///
/// `map_fn` is executed on the Executor set earlier in the pipeline.
pub fn map(
    map_fn: anytype,
    ctx: anytype,
) Map(@TypeOf(map_fn), @TypeOf(ctx)) {
    const Ctx = @TypeOf(ctx);
    const ctx_type_info = @typeInfo(Ctx);
    if (ctx_type_info != .@"struct" or !ctx_type_info.@"struct".is_tuple) {
        @compileError("Ctx passed to Map must be a tuple");
    }
    return .{
        .map_fn = map_fn,
        .map_ctx = ctx,
    };
}
