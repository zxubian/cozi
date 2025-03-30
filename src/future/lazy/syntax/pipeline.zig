const std = @import("std");
const assert = std.debug.assert;
const meta = std.meta;

pub fn Result(Args: type) type {
    const IntermediatesType = Intermediates(Args);
    const intermediates_info = @typeInfo(IntermediatesType);
    const args_count = argsCount(Args);
    return intermediates_info.@"struct".fields[args_count - 1].type;
}

pub fn Intermediates(Args: type) type {
    const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
    assert(args_info.is_tuple);
    const args_count = args_info.fields.len;
    var intermediate_fields: [args_count]std.builtin.Type.StructField = undefined;
    var PreviousType: ?type = null;
    var CurrentType: type = undefined;
    for (args_info.fields, &intermediate_fields, 0..) |arg, *intermediate, i| {
        const Future = arg.type;
        if (PreviousType) |prev| {
            CurrentType = Future.Future(prev);
        } else {
            CurrentType = Future;
        }
        PreviousType = CurrentType;
        intermediate.* = .{
            .type = CurrentType,
            .name = std.fmt.comptimePrint("{}", .{i}),
            .alignment = @alignOf(CurrentType),
            .default_value_ptr = null,
            .is_comptime = false,
        };
    }
    const intermediates_tuple_info: std.builtin.Type = .{
        .@"struct" = std.builtin.Type.Struct{
            .layout = .auto,
            .fields = &intermediate_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = true,
        },
    };
    const IntermediatesType = @Type(intermediates_tuple_info);
    return IntermediatesType;
}

fn argsCount(Args: type) usize {
    const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
    assert(args_info.is_tuple);
    const args_count = args_info.fields.len;
    return args_count;
}

pub inline fn pipeline(args: anytype) Result(@TypeOf(args)) {
    const Args = @TypeOf(args);
    const args_count = comptime argsCount(Args);
    const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
    assert(args_info.is_tuple);
    var intermediates: Intermediates(Args) = undefined;
    inline for (&intermediates, args, 0..) |*intermediate, arg, idx| {
        switch (idx) {
            0 => {
                intermediate.* = args[0];
                continue;
            },
            inline else => {
                const prev = intermediates[idx - 1];
                intermediate.* = arg.pipe(prev);
            },
        }
    }
    return intermediates[args_count - 1];
}
