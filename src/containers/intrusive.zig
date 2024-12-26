/// Intrusive singly-linked list.
/// Can be used as either a stack or a queue.
pub const ForwardList = @import("./intrusive/forwardList.zig").IntrusiveForwardList;
pub const LockFree = @import("./intrusive/lockFree.zig");

/// Intrusive Node for singly-linked list-based data structures.
/// When embedding in another struct,
/// the field name must be "intrusive_list_node"
/// for @fieldParentPtr
pub const Node = struct {
    next: ?*Node = null,

    pub fn parentPtr(self: *Node, T: anytype) *T {
        return @fieldParentPtr("intrusive_list_node", self);
    }
};

test {
    _ = ForwardList;
    _ = LockFree;
}
