//! Type-erased interface representing a task that can be run.
//! Can pass a single type-erased pointer as an argument to its run function.
//! Contains an intrusive linked-list node,
//! and can thus be added to linked lists without allocation.
const Containers = @import("../containers/root.zig");

const Runnable = @This();

pub const RunFn = *const fn (ctx: *anyopaque) void;

/// Pointer to run function
runFn: RunFn,
/// Opaque pointer that will be passed to `runFn` when `Runnable.run`
/// is executed
ptr: *anyopaque,
/// Intrusive list node for linking runnables in lists/queues
intrusive_list_node: Containers.Intrusive.Node = .{},

pub inline fn run(self: *Runnable) void {
    self.runFn(self.ptr);
}
