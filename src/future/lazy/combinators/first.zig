const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../root.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../root.zig").core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
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

        pub const ValueType = OutputUnionType;

        pub fn Computation(Continuation: type) type {
            return struct {
                const ComputationType = @This();

                input_computations: InputComputations,
                completed: std.atomic.Value(bool),
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
                            if (all_computation.completed.cmpxchgStrong(
                                false,
                                true,
                                .seq_cst,
                                .seq_cst,
                            ) == null) {
                                all_computation.next.@"continue"(
                                    @unionInit(
                                        ValueType,
                                        computation_field_name_in_tuple,
                                        value,
                                    ),
                                    State{
                                        .executor = executors.@"inline",
                                    },
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

        const OutputUnionType = blk: {
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

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            const Result = Computation(@TypeOf(continuation));
            var result: Result = undefined;
            result.next = continuation;
            result.completed = .init(false);
            inline for (&result.input_computations, 0..) |*computation, i| {
                const Future = comptime getFutureType(i);
                computation.* = self.inputs[i].materialize(
                    Result.InputContinuation(Future, i){},
                );
            }
            return result;
        }

        fn getFutureType(comptime index: usize) type {
            return inputs_type_info.@"struct".fields[index].type;
        }
    };
}

pub fn first(
    inputs: anytype,
) First(@TypeOf(inputs)) {
    return .{ .inputs = inputs };
}
