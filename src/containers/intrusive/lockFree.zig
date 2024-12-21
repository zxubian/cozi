const std = @import("std");
const Atomic = std.atomic.Value;
const LockFreeQueue = @This();

/// Multiple-producer single-consumer lock-free intrusive stack
pub fn MpscLockFreeStack(T: type) type {
    return struct {
        const Self = @This();
        /// Intrusive list node
        /// When including in another type, must use
        /// "intrusive_list_node" as field name.
        pub const Node = struct {
            next: Atomic(?*Node) = .init(null),
        };
        top: Atomic(?*Node) = .init(null),
        count: Atomic(usize) = .init(0),

        pub fn pushFront(self: *Self, data: *T) void {
            const node: *Node = &(data.*.intrusive_list_node);
            while (true) {
                const old_top = self.top.load(.seq_cst);
                node.next.store(old_top, .seq_cst);
                if (self.top.cmpxchgWeak(old_top, node, .seq_cst, .seq_cst) == null) {
                    break;
                }
            }
            _ = self.count.fetchAdd(1, .seq_cst);
        }

        pub fn popFront(self: *Self) ?*T {
            const result_node: ?*Node = blk: {
                while (true) {
                    if (self.top.load(.seq_cst)) |top| {
                        const next = top.next.load(.seq_cst);
                        if (self.top.cmpxchgWeak(top, next, .seq_cst, .seq_cst) == null) {
                            break :blk top;
                        }
                    } else {
                        break :blk null;
                    }
                }
            };
            if (result_node) |result| {
                _ = self.count.fetchSub(1, .seq_cst);
                return @fieldParentPtr("intrusive_list_node", result);
            } else {
                return null;
            }
        }
    };
}

/// Multiple-producer single-consumer intrusive lock-free queue
pub fn MpscLockFreeQueue(T: type) type {
    return struct {
        const Stack = MpscLockFreeStack(T);
        pub const Node = Stack.Node;
        const Self = @This();

        input: Stack align(std.atomic.cache_line) = .{},
        output: Stack align(std.atomic.cache_line) = .{},
        count: Atomic(usize) align(std.atomic.cache_line) = .init(0),

        pub fn pushBack(self: *Self, data: *T) void {
            self.input.pushFront(data);
            _ = self.count.fetchAdd(1, .seq_cst);
        }

        pub fn popFront(self: *Self) ?*T {
            if (self.output.count.load(.seq_cst) == 0) {
                const count = self.input.count.load(.seq_cst);
                for (0..count) |_| {
                    const data = self.input.popFront().?;
                    self.output.pushFront(data);
                }
            }
            _ = self.count.fetchSub(1, .seq_cst);
            return self.output.popFront();
        }
    };
}

test {
    _ = @import("./lockFree/tests.zig");
}
