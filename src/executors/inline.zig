const std = @import("std");
const Executor = @import("./main.zig").Executor;
const core = @import("../main.zig").core;
const Runnable = core.Runnable;
const InlineExecutor = @This();

pub const executor: Executor = .{
    .vtable = .{ .submit = InlineExecutor.Submit },
    .ptr = undefined,
};

pub fn Submit(_: *anyopaque, runnable: *Runnable) void {
    runnable.run();
}
