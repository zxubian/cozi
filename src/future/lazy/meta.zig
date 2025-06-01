const std = @import("std");
const Future = @import("./root.zig");
const Model = Future.Model;

pub fn ResultType(ctx: anytype) type {
    const run_function = ctx.run;
    return ReturnType(run_function);
}

pub fn ReturnType(Function: type) type {
    const lambda_info: std.builtin.Type.Fn = @typeInfo(Function).@"fn";
    return lambda_info.return_type.?;
}

pub fn ValidateMapFnArgs(
    InputFuture: type,
    OutputValueType: type,
    UnwrappedValueType: type,
    MapFnArgType: type,
    MapFn: type,
    Ctx: type,
) void {
    if (UnwrappedValueType != MapFnArgType) {
        @compileError(std.fmt.comptimePrint(
            "Incompatible parameter type for map function {} in {} with input future {}. Expected: {}. Got: {}",
            .{
                MapFn,
                @This(),
                InputFuture,
                UnwrappedValueType,
                MapFnArgType,
            },
        ));
    }
    const params_count = blk: {
        var count = std.meta.fields(Ctx).len;
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
                .type = UnwrappedValueType,
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
    const expected_signature_info: std.builtin.Type = .{
        .@"fn" = .{
            .calling_convention = .auto,
            .is_generic = false,
            .is_var_args = false,
            .return_type = OutputValueType,
            .params = &params,
        },
    };
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
