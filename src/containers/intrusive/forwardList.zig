const std = @import("std");

/// Intrusive List Node.
/// When embedding in another struct,
/// the field name must be "intrusive_list_node"
/// for @fieldParentPtr
pub const Node = struct {
    next: ?*Node = null,
};

pub fn IntrusiveForwardList(T: type) type {
    return struct {
        const List = @This();

        head: ?*Node = null,
        tail: ?*Node = null,
        count: usize = 0,

        pub fn isEmpty(self: List) bool {
            return self.count == 0;
        }

        pub fn pushBack(self: *List, data: *T) void {
            const node: *Node = &data.intrusive_list_node;
            defer self.count += 1;
            if (self.isEmpty()) {
                self.head = node;
                self.tail = node;
                return;
            }
            self.tail.?.next = node;
            self.tail = node;
        }

        pub fn pushFront(self: *List, data: *T) void {
            const node: *Node = &data.intrusive_list_node;
            defer self.count += 1;
            if (self.isEmpty()) {
                self.head = node;
                self.tail = node;
                return;
            }
            const old_head = self.head;
            node.next = old_head;
            self.head = node;
        }

        pub fn popFront(self: *List) ?*T {
            if (self.head) |head| {
                self.count -= 1;
                if (head == self.tail.?) {
                    self.head = null;
                    self.tail = null;
                    return @fieldParentPtr("intrusive_list_node", head);
                }
                const old_head = head;
                const new_head = old_head.next;
                self.head = new_head;
                return @fieldParentPtr("intrusive_list_node", old_head);
            }
            return null;
        }

        pub fn reset(self: *List) void {
            self.head = null;
            self.tail = null;
            self.count = 0;
        }

        pub fn print(self: *List) void {
            std.debug.print(
                "printing intrusive list {*}\n",
                .{self},
            );
            if (self.head) |head| {
                var next = head.next;
                while (next != null) : (next = next.?.next) {
                    std.debug.print("{} -> ", .{next});
                }
            } else {
                std.debug.print("{*}: empty", .{self});
            }
        }
    };
}

pub fn ThreadSafeIntrusiveForwardList(T: type) type {
    return struct {
        const List = @This();
        const Impl = IntrusiveForwardList(T);

        impl: Impl,
        mutex: std.Thread.Mutex,

        pub fn count(self: *List) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.impl.count;
        }

        pub fn isEmpty(self: *List) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.impl.isEmpty();
        }

        pub fn pushBack(self: *List, node: *Node) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.impl.pushBack(node);
        }

        pub fn pushFront(self: *List, node: *Node) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.impl.pushFront(node);
        }

        pub fn popFront(self: *List) ?*Node {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.impl.popFront();
        }

        pub fn reset(self: *List) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.impl.reset();
        }
    };
}

test {
    _ = @import("./forwardList/tests.zig");
}
