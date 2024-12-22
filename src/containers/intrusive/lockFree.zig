const std = @import("std");
const Atomic = std.atomic.Value;
const LockFreeQueue = @This();

/// Intrusive list node
/// When including in another type, must use
/// "intrusive_list_node" as field name.
pub const Node = struct {
    next: ?*Node = null,
};

///Multiple-producer single-consumer lock-free intrusive stack
pub fn MpscLockFreeStack(T: type) type {
    return struct {
        const Self = @This();
        top: Atomic(?*Node) = .init(null),

        pub fn pushFront(self: *Self, data: *T) void {
            const node: *Node = &(data.*.intrusive_list_node);
            while (true) {
                node.next = self.top.load(.seq_cst);
                if (self.top.cmpxchgWeak(
                    node.next,
                    node,
                    .seq_cst,
                    .seq_cst,
                ) == null) {
                    break;
                }
            }
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.top.load(.seq_cst) == null;
        }

        pub fn consumeAll(
            self: *Self,
            handler: *const fn (
                next_data_ptr: *T,
                ctx: *anyopaque,
            ) void,
            ctx: *anyopaque,
        ) void {
            const head: ?*Node = self.top.swap(null, .seq_cst);
            var current: ?*Node = head;
            while (current) |curr| {
                const next = curr.next;
                handler(@fieldParentPtr("intrusive_list_node", curr), ctx);
                current = next;
            }
        }

        pub fn popFront(self: *Self) ?*T {
            const result_node: ?*Node = blk: {
                while (true) {
                    if (self.top.load(.seq_cst)) |top| {
                        if (self.top.cmpxchgWeak(
                            top,
                            top.next,
                            .seq_cst,
                            .seq_cst,
                        ) == null) {
                            break :blk top;
                        }
                    } else {
                        break :blk null;
                    }
                }
            };
            if (result_node) |result| {
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
        const Self = @This();

        input: Stack align(std.atomic.cache_line) = .{},
        output: Stack align(std.atomic.cache_line) = .{},

        pub fn pushBack(self: *Self, data: *T) void {
            self.input.pushFront(data);
        }

        pub fn popFront(self: *Self) ?*T {
            if (self.output.isEmpty()) {
                const Ctx = struct {
                    pub fn handler(data: *T, ctx: *anyopaque) void {
                        var self_: *Self = @alignCast(@ptrCast(ctx));
                        self_.output.pushFront(data);
                    }
                };
                self.input.consumeAll(Ctx.handler, self);
            }
            return self.output.popFront();
        }
    };
}

test {
    _ = @import("./lockFree/tests.zig");
}
