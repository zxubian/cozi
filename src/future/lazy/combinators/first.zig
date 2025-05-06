const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../../root.zig");
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future.lazy;
const State = future.State;

pub fn First(Inputs: type) type {
    const inputs_type_info = @typeInfo(Inputs);
    if (std.meta.activeTag(inputs_type_info) != .@"struct") {
        @compileError("Input of `first` must be a tuple (e.g. .{future_a, future_b,})");
    }
    if (!inputs_type_info.@"struct".is_tuple) {
        @compileError("Input of `first` must be a tuple (e.g. .{future_a, future_b,})");
    }
    const inputs_count: usize = comptime inputs_type_info.@"struct".fields.len;
    return struct {
        inputs: Inputs,

        pub const OutputUnionType = blk: {
            assert(inputs_type_info.@"struct".is_tuple);
            var output_fields: [inputs_count]std.builtin.Type.UnionField = undefined;
            var output_tag_fields: [inputs_count]std.builtin.Type.EnumField = undefined;
            for (
                inputs_type_info.@"struct".fields,
                &output_fields,
                &output_tag_fields,
                0..,
            ) |input_future, *output_field, *output_tag_field, i| {
                const T = input_future.type.ValueType;
                const name = std.fmt.comptimePrint("{}", .{i});
                output_field.* = std.builtin.Type.UnionField{
                    .name = name,
                    .type = T,
                    .alignment = @alignOf(T),
                };
                output_tag_field.* = std.builtin.Type.EnumField{
                    .name = name,
                    .value = i,
                };
            }
            const result_tag_type_info: std.builtin.Type = .{
                .@"enum" = std.builtin.Type.Enum{
                    .tag_type = usize,
                    .fields = &output_tag_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_exhaustive = true,
                },
            };
            const ResultTag = @Type(result_tag_type_info);
            const result_type_info: std.builtin.Type = .{
                .@"union" = std.builtin.Type.Union{
                    .layout = .auto,
                    .tag_type = ResultTag,
                    .fields = &output_fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                },
            };
            break :blk @Type(result_type_info);
        };

        pub fn Future(PipeInputFuture: type) type {
            if (PipeInputFuture.ValueType != void) {
                @compileError("Future preceeding `first` in the pipeline must have a value type of void");
            }
            return struct {
                pipe_input_future: PipeInputFuture,
                inputs: Inputs,

                pub const ValueType = OutputUnionType;

                pub fn Computation(Continuation: type) type {
                    return struct {
                        pipe_input_computation: PipeInputComputation,
                        input_computations: InputComputations,
                        completed: cozi.fault.stdlike.atomic.Value(bool),
                        next: Continuation,
                        value: OutputUnionType = undefined,
                        input_computation_runnables: [inputs_count]Runnable = undefined,

                        const Impl = @This();
                        const PipeInputComputation = PipeInputFuture.Computation(PipeContinuation);

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

                        fn inputContinue(ctx: *anyopaque) void {
                            const self: *Impl = @alignCast(@ptrCast(ctx));
                            self.next.@"continue"(
                                self.value,
                                .init,
                            );
                        }

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
                                    state: State,
                                ) void {
                                    const computation: *F.Computation(@This()) =
                                        @alignCast(@fieldParentPtr("next", self));
                                    const computation_field_name_in_tuple = std.fmt.comptimePrint(
                                        "{}",
                                        .{index},
                                    );
                                    const input_computations: *InputComputations = @alignCast(
                                        @fieldParentPtr(
                                            computation_field_name_in_tuple,
                                            computation,
                                        ),
                                    );
                                    const first_computation: *Impl = @alignCast(
                                        @fieldParentPtr(
                                            "input_computations",
                                            input_computations,
                                        ),
                                    );
                                    if (first_computation.completed.cmpxchgStrong(
                                        false,
                                        true,
                                        .seq_cst,
                                        .seq_cst,
                                    )) |_| {
                                        // lost the race
                                        return;
                                    }
                                    first_computation.value = @unionInit(
                                        ValueType,
                                        computation_field_name_in_tuple,
                                        value,
                                    );
                                    self.runnable = .{
                                        .runFn = inputContinue,
                                        .ptr = first_computation,
                                    };
                                    state.executor.submitRunnable(&self.runnable);
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
                    var result: Result = .{
                        .next = continuation,
                        .completed = .init(false),
                        .pipe_input_computation = self.pipe_input_future.materialize(Result.PipeContinuation{}),
                        .input_computations = undefined,
                    };
                    inline for (&result.input_computations, 0..) |*computation, i| {
                        const InputFuture = comptime getFutureType(i);
                        computation.* = self.inputs[i].materialize(
                            Result.InputContinuation(InputFuture, i){},
                        );
                    }
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

/// A Future that is resolved when THE FIRST
/// provided future is resolved.
///
/// The computation of each Future from `inputs` is
/// executed on last `Executor` set in the pipeline.
///
/// The resulting value is a Union whose fields
/// are result values of each supplied Future,
/// in the same order as the input Futures.
///
/// `first` resets the `Executor` of the pipeline
///  to `executors.@"inline"`` for succeeding Futures.
pub fn first(
    inputs: anytype,
) First(@TypeOf(inputs)) {
    return .{ .inputs = inputs };
}
