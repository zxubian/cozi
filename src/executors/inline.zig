const std = @import("std");
const Executor = @import("../executors.zig").Executor;
const Runnable = @import("../executors.zig").Runnable;

pub fn Submit(_: *Executor, runnable: *Runnable) void {
    runnable.runFn();
}
