const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../root.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../root.zig").core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
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

        pub const ValueType = OutputTupleType;

        pub fn Computation(Continuation: type) type {
            return struct {
                const ComputationType = @This();

                input_computations: InputComputations,
                value: ValueType = undefined,
                rendezvous_state: std.atomic.Value(usize),
                next: Continuation,

                pub fn start(self: *@This()) void {
                    inline for (&self.input_computations) |*computation| {
                        computation.start();
                    }
                }

                fn InputContinuation(F: type, comptime computation_index: usize) type {
                    return struct {
                        const index: usize = computation_index;
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
                            const all_computation: *ComputationType = @alignCast(
                                @fieldParentPtr(
                                    "input_computations",
                                    input_computations,
                                ),
                            );
                            all_computation.value[index] = value;
                            if (all_computation.rendezvous_state.fetchSub(1, .seq_cst) - 1 == 0) {
                                all_computation.next.@"continue"(all_computation.value, State{
                                    .executor = executors.@"inline",
                                });
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
                        const Future = input_future.type;
                        output_field.* = .{
                            .name = std.fmt.comptimePrint("{}", .{i}),
                            .type = Future.Computation(InputContinuation(Future, i)),
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

        const OutputTupleType = blk: {
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

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            const Result = Computation(@TypeOf(continuation));
            var result: Result = undefined;
            result.next = continuation;
            result.rendezvous_state = .init(inputs_count);
            inline for (&result.input_computations, 0..) |*computation, i| {
                const Future = comptime getFutureType(i);
                computation.* = self.inputs[i].materialize(Result.InputContinuation(Future, i){});
            }
            return result;
        }

        fn getFutureType(comptime index: usize) type {
            return inputs_type_info.@"struct".fields[index].type;
        }
    };
}

/// A Future that is resolved when ALL
/// of the input futures are resolved.
/// The resolved value is a Tuple containing
/// the result values of each supplied Future,
/// in the same order as the input Futures.
/// `all` resets the Executor of the pipeline
///  to @"inline" for succeeding Futures.
pub fn all(
    inputs: anytype,
) All(@TypeOf(inputs)) {
    return .{ .inputs = inputs };
}
