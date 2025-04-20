const std = @import("std");
const fault = @import("../../fault/root.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const LockFreeQueue = @This();
const Node = @import("../intrusive.zig").Node;

// TODO: add Michael-Scott Queue

/// Multiple-producer single-consumer lock-free intrusive stack
/// Treiber, R.K., 1986. Systems programming: Coping with parallelism.
/// Note: using with multiple consumers will result in ABA problem.
pub fn MpscStack(T: type) type {
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
                handler(curr.parentPtr(T), ctx);
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
                return result.parentPtr(T);
            } else {
                return null;
            }
        }
    };
}

/// Multiple-producer single-consumer intrusive lock-free queue
pub fn MpscQueue(T: type) type {
    return struct {
        const Stack = MpscStack(T);
        const Self = @This();

        inbox: Stack align(std.atomic.cache_line) = .{},
        outbox: Stack align(std.atomic.cache_line) = .{},

        pub fn pushBack(self: *Self, data: *T) void {
            return self.inbox.pushFront(data);
        }

        pub fn popFront(self: *Self) ?*T {
            if (self.outbox.isEmpty()) {
                const Ctx = struct {
                    pub fn handler(data: *T, ctx: *anyopaque) void {
                        var self_: *Self = @alignCast(@ptrCast(ctx));
                        self_.outbox.pushFront(data);
                    }
                };
                self.inbox.consumeAll(Ctx.handler, self);
            }
            return self.outbox.popFront();
        }

        pub fn consumeAll(
            self: *Self,
            handler: *const fn (
                next_data_ptr: *T,
                ctx: *anyopaque,
            ) void,
            ctx: *anyopaque,
        ) void {
            var temp: Stack = .{};
            const Ctx = struct {
                pub fn addToTemp(data: *T, ctx_temp: *anyopaque) void {
                    var temp_: *Stack = @alignCast(@ptrCast(ctx_temp));
                    temp_.pushFront(data);
                }
            };
            // move all pending inbox nodes to temp
            self.inbox.consumeAll(Ctx.addToTemp, &temp);
            // send out all pending nodes from outbox
            self.outbox.consumeAll(handler, ctx);
            // send out all pendings node from temp
            temp.consumeAll(handler, ctx);
        }
    };
}

test {
    _ = @import("./lockFree/tests.zig");
}
