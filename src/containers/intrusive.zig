pub const ForwardList = @import("./intrusive/forwardList.zig").IntrusiveForwardList;
pub const BatchedQueue = @import("./intrusive/batchedQueue.zig").BatchedQueue;

pub const LockFree = @import("./intrusive/lockFree.zig");

/// Intrusive Node for singly-linked list-based data structures.
/// When embedding in another struct,
/// the field name must be "intrusive_list_node"
/// for @fieldParentPtr
pub const Node = struct {
    next: ?*Node = null,
};

test {
    _ = ForwardList;
    _ = LockFree;
}
