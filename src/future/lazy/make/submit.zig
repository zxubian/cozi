const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../root.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../root.zig").core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
const State = future.State;
const model = future.model;
const Computation = model.Computation;
const meta = future.meta;
const f = future.Impl;

pub fn Future(Lambda: type, Ctx: type) type {
    return future.syntax.pipeline.Result(std.meta.Tuple(&[_]type{
        future.make.just,
        future.combinators.via,
        future.combinators.map.Map(Lambda, Ctx),
    }));
}

/// Returns a Future that submits `lambda` to `executor`,
/// and resolves when the submitted lambda function returns.
/// * -> Future<lambda(ctx)>
pub inline fn submit(
    executor: Executor,
    lambda: anytype,
    lambda_ctx_tuple: std.meta.ArgsTuple(@TypeOf(lambda)),
) Future(
    @TypeOf(lambda),
    @TypeOf(lambda_ctx_tuple),
) {
    return f.pipeline(.{
        f.just(),
        f.via(executor),
        f.map(
            lambda,
            lambda_ctx_tuple,
        ),
    });
}
