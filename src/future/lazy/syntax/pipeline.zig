const std = @import("std");
const assert = std.debug.assert;
const meta = std.meta;

pub fn PipelineResult(Args: type) type {
    const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
    assert(args_info.is_tuple);
    var PreviousType: ?type = null;
    var CurrentType: type = undefined;
    for (args_info.fields) |field| {
        const Future = field.type;
        if (PreviousType) |prev| {
            CurrentType = Future.PipeType(prev);
        } else {
            CurrentType = Future.ValueType;
        }
        PreviousType = CurrentType;
    }
    return CurrentType;
}

pub fn pipeline(args: anytype) PipelineResult(@TypeOf(args)) {
    unreachable;
    // const arg_count = comptime blk: {
    //     const Args = @TypeOf(args);
    //     const args_info: std.builtin.Type.Struct = @typeInfo(Args).@"struct";
    //     break :blk args_info.fields.len;
    // };
}
