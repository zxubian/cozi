//! Inline Executor immediately executes submitted `Runnable`
const std = @import("std");
const Executor = @import("./root.zig").Executor;
const core = @import("../root.zig").core;
const Runnable = core.Runnable;
const InlineExecutor = @This();

pub const executor: Executor = .{
    .vtable = .{ .submit = InlineExecutor.Submit },
    .ptr = undefined,
};

pub fn Submit(_: *anyopaque, runnable: *Runnable) void {
    runnable.run();
}

test "executors - inline" {
    const inline_executor = InlineExecutor.executor;
    const Ctx = struct {
        done: bool,
        pub fn run(self: *@This()) void {
            self.done = true;
        }
    };
    var ctx: Ctx = .{ .done = false };
    // on submit, Ctx.run(&ctx) is executed immediately
    inline_executor.submit(Ctx.run, .{&ctx}, std.testing.allocator);
    try std.testing.expect(ctx.done);
}
