const std = @import("std");
const assert = std.debug.assert;
const Future = @import("./root.zig");
const Model = Future.Model;

/// Returns the `type` of the value returned by `Function`
pub fn ReturnType(Function: type) type {
    const lambda_info: std.builtin.Type.Fn = @typeInfo(Function).@"fn";
    return lambda_info.return_type.?;
}

/// Returns a new `type` that is a tuple with the following fields (in order):
/// - all fields of `Input` (in the same order as `Input`)
/// - one field per type in `Args` (in the same order as in the `Args` array)
pub fn CombineTuple(Input: type, args: []const type) type {
    const input_type_info: std.builtin.Type.Struct = @typeInfo(Input).@"struct";
    comptime assert(input_type_info.is_tuple);
    const input_field_count = input_type_info.fields.len;
    const args_count = args.len;
    const output_field_count = input_field_count + args_count;
    var output_fields: [output_field_count]std.builtin.Type.StructField = undefined;
    comptime var i: usize = 0;
    inline for (input_type_info.fields, 0..) |input_field, input_idx| {
        i = input_idx;
        output_fields[i] = input_field;
    }
    inline for (args, 0..) |Arg, args_idx| {
        i = args_idx + input_field_count;
        output_fields[i] = std.builtin.Type.StructField{
            .name = std.fmt.comptimePrint("{}", .{i}),
            .type = Arg,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Arg),
        };
    }
    const output_type_info: std.builtin.Type.Struct = .{
        .layout = .auto,
        .fields = &output_fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = true,
    };
    return @Type(output_type_info);
}
