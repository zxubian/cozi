const std = @import("std");
const Future = @import("./main.zig");
const Model = Future.Model;

pub fn ResultType(ctx: anytype) type {
    const run_function = ctx.run;
    return ReturnType(run_function);
}

pub fn ReturnType(Function: type) type {
    const lambda_info: std.builtin.Type.Fn = @typeInfo(Function).@"fn";
    return lambda_info.return_type.?;
}
