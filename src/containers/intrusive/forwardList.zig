//! Intrusive singly-linked list.
//! Can be used as either a stack or a queue.
const std = @import("std");
const assert = std.debug.assert;
const Node = @import("../intrusive.zig").Node;

pub fn IntrusiveForwardList(T: type) type {
    return struct {
        const List = @This();

        head: ?*Node = null,
        tail: ?*Node = null,
        count: usize = 0,

        pub fn isEmpty(self: List) bool {
            if (self.count == 0) {
                assert(self.head == null);
                assert(self.tail == null);
                return true;
            }
            assert(self.head != null);
            assert(self.tail != null);
            return false;
        }

        pub fn pushBack(self: *List, data: *T) void {
            const node: *Node = &data.intrusive_list_node;
            defer self.count += 1;
            if (self.isEmpty()) {
                // null <- node = head = tail
                self.head = node;
            }
            // null <- head <- ... <- old_tail <- node
            const old_tail = self.tail;
            node.next = old_tail;
            self.tail = node;
        }

        pub fn pushFront(self: *List, data: *T) void {
            const node: *Node = &data.intrusive_list_node;
            defer self.count += 1;
            node.next = null;
            if (self.isEmpty()) {
                // null <- node = head = tail
                self.tail = node;
            }
            // node <- old_head <- ... <- tail
            const old_head = self.head;
            if (old_head) |old| {
                old.next = node;
            }
            self.head = node;
        }

        pub fn popFront(self: *List) ?*T {
            switch (self.count) {
                0 => return null,
                1 => {
                    defer self.count -= 1;
                    assert(self.head == self.tail);
                    assert(self.head != null);
                    assert(self.head.?.next == null);
                    const result = self.head.?.parentPtr(T);
                    self.head = null;
                    self.tail = null;
                    return result;
                },
                2 => {
                    defer self.count -= 1;
                    // head </- <- tail
                    assert(self.tail.?.next == self.head);
                    const result = self.head.?.parentPtr(T);
                    self.head = self.tail;
                    self.tail.?.next = null;
                    return result;
                },
                else => {
                    defer self.count -= 1;
                    assert(self.head != self.tail);
                    assert(self.tail.?.next != null);
                    const next_head: *Node = blk: {
                        var current: *Node = self.tail.?;
                        break :blk while (current.next) |next| : (current = next) {
                            if (next == self.head) {
                                break current;
                            }
                        } else unreachable;
                    };
                    // head </- next_head <- .. <- tail
                    const result = self.head.?.parentPtr(T);
                    next_head.next = null;
                    self.head = next_head;
                    return result;
                },
            }
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
                    std.debug.print("{?} -> ", .{next});
                }
            } else {
                std.debug.print("{*}: empty\n", .{self});
            }
        }
    };
}

test {
    _ = @import("./forwardList/tests.zig");
}
