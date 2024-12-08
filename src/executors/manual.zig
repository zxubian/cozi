const std = @import("std");
const Executor = @import("../executor.zig");
const Runnable = @import("../runnable.zig");
const Queue = @import("../containers/intrusive/forwardList.zig").IntrusiveForwardList(Runnable);
const Allocator = std.mem.Allocator;

/// Single-threaded manually-executed task queue
const ManualExecutor = @This();
tasks: Queue = .{},

pub fn submit(ctx: *anyopaque, runnable: *Runnable) void {
    var self: *ManualExecutor = @alignCast(@ptrCast(ctx));
    self.tasks.pushBack(runnable);
}

/// Run at most `limit` tasks from queue
/// Returns number of completed tasks
pub fn runAtMost(self: *ManualExecutor, limit: usize) usize {
    var run_count: usize = 0;
    while (run_count < limit) : (run_count += 1) {
        const runnable = self.tasks.popFront() orelse break;
        runnable.run();
    }
    return run_count;
}

/// Run next task if queue is not empty
pub fn runNext(
    self: *ManualExecutor,
) bool {
    return self.runAtMost(1) == 1;
}

pub inline fn isEmpty(self: *const ManualExecutor) bool {
    return self.tasks.isEmpty();
}

/// Run tasks until queue is empty
/// Returns number of completed tasks
/// Post-condition: isEmpty() == true
pub fn drain(self: *ManualExecutor) usize {
    var run_count: usize = 0;
    while (self.tasks.popFront()) |runnable| : (run_count += 1) {
        runnable.run();
    }
    return run_count;
}

pub fn count(self: *ManualExecutor) usize {
    return self.tasks.count;
}

pub fn executor(self: *ManualExecutor) Executor {
    return Executor{
        .vtable = .{
            .submit = ManualExecutor.submit,
        },
        .ptr = self,
    };
}

test {
    _ = @import("./manual/tests.zig");
}
