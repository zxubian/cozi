const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../../root.zig");
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future.lazy;
const State = future.State;

pub fn All(Inputs: type) type {
    const inputs_type_info = @typeInfo(Inputs);
    if (std.meta.activeTag(inputs_type_info) != .@"struct") {
        @compileError("Input of `all` must be a tuple (e.g. .{future_a, future_b,})");
    }
    if (!inputs_type_info.@"struct".is_tuple) {
        @compileError("Input of `all` must be a tuple (e.g. .{future_a, future_b,})");
    }
    const inputs_count: usize = comptime inputs_type_info.@"struct".fields.len;

    return struct {
        inputs: Inputs,
        pub const OutputTupleType = blk: {
            assert(inputs_type_info.@"struct".is_tuple);
            var output_fields: [inputs_count]std.builtin.Type.StructField = undefined;
            for (
                inputs_type_info.@"struct".fields,
                &output_fields,
                0..,
            ) |input_future, *output_field, i| {
                output_field.* = .{
                    .name = std.fmt.comptimePrint("{}", .{i}),
                    .type = input_future.type.ValueType,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(input_future.type.ValueType),
                };
            }
            const result_type_info: std.builtin.Type = .{
                .@"struct" = std.builtin.Type.Struct{
                    .layout = .auto,
                    .fields = &output_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = true,
                },
            };
            break :blk @Type(result_type_info);
        };

        pub fn Future(PipeInputFuture: type) type {
            if (PipeInputFuture.ValueType != void) {
                @compileError("Future preceeding `all` in the pipeline must have a value type of void");
            }
            return struct {
                pipe_input_future: PipeInputFuture,
                inputs: Inputs,

                pub const ValueType = OutputTupleType;

                pub fn Computation(Continuation: type) type {
                    return struct {
                        pipe_input_computation: PipeInputComputation,
                        input_computations: InputComputations,
                        input_computation_runnables: [inputs_count]Runnable,
                        value: ValueType = undefined,
                        rendezvous_state: cozi.fault.stdlike.atomic.Value(usize),
                        next: Continuation,

                        const PipeInputComputation = PipeInputFuture.Computation(PipeContinuation);
                        const Impl = @This();

                        pub fn start(self: *@This()) void {
                            self.pipe_input_computation.start();
                        }

                        fn pipeContinue(ctx: *anyopaque) void {
                            const pipe_input_continuation: *PipeContinuation =
                                @alignCast(@ptrCast(ctx));
                            const pipe_input_computation: *PipeInputComputation = @fieldParentPtr(
                                "next",
                                pipe_input_continuation,
                            );
                            const self: *Impl = @fieldParentPtr(
                                "pipe_input_computation",
                                pipe_input_computation,
                            );
                            const executor = pipe_input_continuation.state.executor;
                            inline for (
                                &self.input_computations,
                                &self.input_computation_runnables,
                            ) |*computation, *runnable| {
                                const InputComputation = @TypeOf(computation.*);
                                runnable.* = .{
                                    .runFn = @ptrCast(&InputComputation.start),
                                    .ptr = computation,
                                };
                                executor.submitRunnable(runnable);
                            }
                        }

                        const PipeContinuation = struct {
                            state: State = undefined,
                            runnnable: Runnable = undefined,

                            pub fn @"continue"(
                                self: *@This(),
                                _: PipeInputFuture.ValueType,
                                state: State,
                            ) void {
                                self.state = state;
                                self.runnnable = .{
                                    .runFn = pipeContinue,
                                    .ptr = self,
                                };
                                self.state.executor.submitRunnable(&self.runnnable);
                            }
                        };

                        fn InputContinuation(
                            F: type,
                            comptime computation_index: usize,
                        ) type {
                            return struct {
                                const index: usize = computation_index;
                                runnable: Runnable = undefined,
                                pub fn @"continue"(
                                    self: *@This(),
                                    value: F.ValueType,
                                    _: State,
                                ) void {
                                    const computation: *F.Computation(@This()) = @alignCast(@fieldParentPtr("next", self));
                                    const computation_field_name_in_tuple = std.fmt.comptimePrint("{}", .{index});
                                    const input_computations: *InputComputations = @alignCast(
                                        @fieldParentPtr(
                                            computation_field_name_in_tuple,
                                            computation,
                                        ),
                                    );
                                    const all_computation: *Impl = @alignCast(
                                        @fieldParentPtr(
                                            "input_computations",
                                            input_computations,
                                        ),
                                    );
                                    all_computation.value[index] = value;
                                    if (all_computation.rendezvous_state.fetchSub(1, .seq_cst) - 1 == 0) {
                                        // reset state to "inline"
                                        all_computation.next.@"continue"(
                                            all_computation.value,
                                            .init,
                                        );
                                    }
                                }
                            };
                        }

                        const InputComputations = blk: {
                            assert(inputs_type_info.@"struct".is_tuple);
                            var output_fields: [inputs_count]std.builtin.Type.StructField = undefined;
                            for (
                                inputs_type_info.@"struct".fields,
                                &output_fields,
                                0..,
                            ) |input_future, *output_field, i| {
                                const InputFuture = input_future.type;
                                output_field.* = .{
                                    .name = std.fmt.comptimePrint("{}", .{i}),
                                    .type = InputFuture.Computation(InputContinuation(InputFuture, i)),
                                    .default_value_ptr = null,
                                    .is_comptime = false,
                                    .alignment = 0,
                                };
                            }
                            const result_type_info: std.builtin.Type = .{
                                .@"struct" = std.builtin.Type.Struct{
                                    .layout = .auto,
                                    .fields = &output_fields,
                                    .decls = &[_]std.builtin.Type.Declaration{},
                                    .is_tuple = true,
                                },
                            };
                            break :blk @Type(result_type_info);
                        };
                    };
                }

                pub fn materialize(
                    self: @This(),
                    continuation: anytype,
                ) Computation(@TypeOf(continuation)) {
                    const Result = Computation(@TypeOf(continuation));
                    var result: Result = undefined;
                    result.next = continuation;
                    result.rendezvous_state = .init(inputs_count);
                    inline for (&result.input_computations, 0..) |*computation, i| {
                        const F = comptime getFutureType(i);
                        computation.* = self.inputs[i].materialize(Result.InputContinuation(F, i){});
                    }
                    result.pipe_input_computation = self.pipe_input_future.materialize(
                        Result.PipeContinuation{},
                    );
                    return result;
                }

                fn getFutureType(comptime index: usize) type {
                    return inputs_type_info.@"struct".fields[index].type;
                }

                pub fn awaitable(self: @This()) future.Awaitable(@This()) {
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
                .pipe_input_future = f,
                .inputs = self.inputs,
            };
        }
    };
}

/// A Future that is resolved when ALL of the input futures are
/// resolved.
///
/// * The computation of each Future from `inputs` is executed on
/// the last `Executor` set earlier in the pipeline.
///
/// * The resolved value is a `std.meta.Tuple` containing the result
/// values of each supplied Future, in the same order as the input
/// Futures.
///
/// * `all` resets the Executor of the pipeline to `executors.@"inline"`
/// for succeeding Futures.
pub fn all(
    inputs: anytype,
) All(@TypeOf(inputs)) {
    return .{ .inputs = inputs };
}
