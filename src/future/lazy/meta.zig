const std = @import("std");
const Future = @import("./main.zig");
const Model = Future.Model;

pub fn ResultType(ctx: anytype) type {
    const run_function = ctx.run;
    return ReturnType(run_function);
}

pub fn ReturnType(function: anytype) type {
    const Lambda = @TypeOf(function);
    const lambda_info: std.builtin.Type.Fn = @typeInfo(Lambda).@"fn";
    return lambda_info.return_type.?;
}
