const std = @import("std");
const Node = @import("../intrusive.zig").Node;

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

test {
    _ = @import("./forwardList/tests.zig");
}
