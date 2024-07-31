const std = @import("std");
const Executor = @import("../executors.zig").Executor;
const Runnable = @import("../executors.zig").Runnable;
const Queue = std.DoublyLinkedList(*Runnable);

/// Single-threaded manually-executed task queue
const ManualExecutor = @This();
tasks: Queue = .{},
allocator: std.mem.Allocator,
executor: Executor = .{
    .vtable = .{
        .submitFn = ManualExecutor.submit,
    },
},

pub fn init(allocator: std.mem.Allocator) ManualExecutor {
    return ManualExecutor{
        .allocator = allocator,
    };
}

pub fn submit(exec: *Executor, runnable: *Runnable) void {
    var self: *ManualExecutor = @fieldParentPtr("executor", exec);
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
/// Post-condition: IsEmpty() == true
pub fn drain(self: *ManualExecutor) usize {
    var run_count: usize = 0;
    while (self.tasks.popFirst()) |node| : (run_count += 1) {
        self.runNode(node);
    }
    return run_count;
}

test {
    _ = @import("./manual/tests.zig");
}
