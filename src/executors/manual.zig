const std = @import("std");
const Executor = @import("../executor.zig");
const Runnable = @import("../runnable.zig");
const Queue = std.DoublyLinkedList(*Runnable);
const Allocator = std.mem.Allocator;

/// Single-threaded manually-executed task queue
const ManualExecutor = @This();
tasks: Queue = .{},
allocator: Allocator,

pub fn init(allocator: Allocator) ManualExecutor {
    return ManualExecutor{
        .allocator = allocator,
    };
}

pub fn submit(ctx: *anyopaque, runnable: *Runnable) void {
    var self: *ManualExecutor = @alignCast(@ptrCast(ctx));
    const node = self.allocator.create(Queue.Node) catch |e| {
        std.debug.panic("{}", .{e});
    };
    node.* = .{ .data = runnable };
    self.tasks.append(node);
}

/// Run at most `limit` tasks from queue
/// Returns number of completed tasks
pub fn runAtMost(self: *ManualExecutor, limit: usize) usize {
    var run_count: usize = 0;
    while (run_count < limit) : (run_count += 1) {
        const node = self.tasks.popFirst() orelse break;
        self.runNode(node);
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
    return self.tasks.len == 0;
}

pub inline fn count(self: *const ManualExecutor) usize {
    return self.tasks.len;
}

fn runNode(self: *ManualExecutor, node: *Queue.Node) void {
    node.data.runFn(node.data);
    self.allocator.destroy(node);
}

/// Run tasks until queue is empty
/// Returns number of completed tasks
/// Post-condition: isEmpty() == true
pub fn drain(self: *ManualExecutor) usize {
    var run_count: usize = 0;
    while (self.tasks.popFirst()) |node| : (run_count += 1) {
        self.runNode(node);
    }
    return run_count;
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
