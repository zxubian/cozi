const std = @import("std");
const Executor = @import("../executor.zig");
const Runnable = @import("../executors.zig").Runnable;
const InlineExecutor = @This();

executor: Executor = .{
    .vtable = .{ .submitFn = InlineExecutor.Submit },
},

pub fn Submit(_: *Executor, runnable: *Runnable) void {
    runnable.run(runnable);
}
