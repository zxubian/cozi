const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../../root.zig");
const executors = cozi.executors;
const InlineExecutor = executors.@"inline";
const Executor = executors.Executor;
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future;
const State = future.State;
const model = future.model;
const meta = future.meta;

const Never = @This();
pub const ValueType = void;

pub fn Computation(Continuation: type) type {
    return struct {
        next: Continuation,
        cancel_context: cozi.cancel.Context = .{},
        on_cancel: Runnable,

        pub fn start(_: *@This()) void {}

        pub fn onCancel(self: *@This()) void {
            self.next.cancel(
                //state
                .init,
            );
        }
    };
}

pub fn materialize(
    _: @This(),
    continuation: anytype,
    computation_storage: *Computation(@TypeOf(continuation)),
) void {
    const ComputationImpl = Computation(@TypeOf(continuation));
    computation_storage.* = .{
        .next = continuation,
        .on_cancel = .{
            .runFn = @ptrCast(&ComputationImpl.onCancel),
            .ptr = computation_storage,
        },
    };
    computation_storage.cancel_context.addCancellationListener(
        &computation_storage.on_cancel,
    ) catch |e| switch (e) {
        error.already_cancelled => {
            computation_storage.on_cancel.run();
        },
        else => unreachable,
    };
}

/// A Future that never returns anything
/// * -> Future<void>
pub fn never() Never {
    return .{};
}

pub fn awaitable(self: Never) future.lazy.Awaitable(Never) {
    return .{ .future = self };
}
