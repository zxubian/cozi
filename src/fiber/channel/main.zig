const std = @import("std");
const log = std.log.scoped(.fiber_channel);
const assert = std.debug.assert;

const sync = @import("../../sync/main.zig");
const Spinlock = sync.Spinlock;

const fault = @import("../../fault/main.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const GenericAwait = @import("../../await/main.zig");
const Awaiter = GenericAwait.Awaiter;
const Await = GenericAwait.@"await";

const Containers = @import("../../containers/main.zig");
const Queue = Containers.Intrusive.ForwardList;
const Node = Containers.Intrusive.Node;

const Fiber = @import("../main.zig");

const select_ = @import("./select/main.zig");
pub const select = select_.select;

pub const PendingOperation = struct {
    pub const Operation = union(enum) {
        send: struct {
            value: *const anyopaque,
            value_taken: *Atomic(bool),
            fiber: *Fiber,

            pub fn get(self: @This(), T: type) T {
                const ptr: *const T = @alignCast(@ptrCast(self.value));
                return ptr.*;
            }
        },

        receive: struct {
            result_ptr: *anyopaque,
            result_set: *Atomic(bool),
            fiber: *Fiber,

            pub fn trySet(self: @This(), T: type, value: ?T) bool {
                if (self.result_set.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
                    const result: *?T = @alignCast(@ptrCast(self.result_ptr));
                    result.* = value;
                    return true;
                }
                return false;
            }
        },
        select_receive: struct {
            result_ptr: *anyopaque,
            result_set: *Atomic(bool),
            result_case: *u16,
            this_case: u16,
            fiber: *Fiber,

            pub fn trySet(self: @This(), T: type, value: anytype) bool {
                if (self.result_set.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
                    const result: *?T = @alignCast(@ptrCast(self.result_ptr));
                    result.* = value;
                    self.result_case.* = self.this_case;
                    return true;
                }
                return false;
            }
        },
    };
    intrusive_list_node: Node = .{},
    operation: Operation,
};

fn SendAwaiter(T: type) type {
    return struct {
        const Self = @This();
        channel: *Channel(T),
        guard: *Spinlock.Guard,
        value: *const T,
        value_taken: Atomic(bool) = .init(false),
        fiber: *Fiber = undefined,
        pending_operation: PendingOperation = undefined,

        pub fn awaiter(self: *Self) Awaiter {
            return Awaiter{
                .ptr = self,
                .vtable = .{
                    .await_suspend = awaitSuspend,
                },
            };
        }

        pub fn awaitSuspend(
            ctx: *anyopaque,
            handle: *anyopaque,
        ) Awaiter.AwaitSuspendResult {
            const self: *Self = @alignCast(@ptrCast(ctx));
            const fiber: *Fiber = @alignCast(@ptrCast(handle));
            self.fiber = fiber;
            defer self.guard.unlock();
            const channel = self.channel;
            if (channel.peekHead()) |head| {
                log.debug(
                    "{*}: saw {s} as head of operation queue",
                    .{ self, @tagName(std.meta.activeTag(head.operation)) },
                );
                switch (head.operation) {
                    .send => {},
                    .receive => |*receive| {
                        if (receive.trySet(T, self.value.*)) {
                            assert(self.value_taken.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null);
                            defer _ = channel.pending_operations.popFront();
                            log.debug("{*} will transfer to {s}", .{ self, receive.fiber.name });
                            return .{ .symmetric_transfer_next = receive.fiber };
                        }
                    },
                    .select_receive => |select_receive| {
                        if (select_receive.trySet(T, self.value.*)) {
                            assert(self.value_taken.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null);
                            defer _ = channel.pending_operations.popFront();
                            log.debug("{*} will transfer to {s}", .{ self, select_receive.fiber.name });
                            return .{ .symmetric_transfer_next = select_receive.fiber };
                        }
                    },
                }
            }
            log.debug("{*}: will suspend", .{self});
            self.pending_operation = .{
                .operation = .{
                    .send = .{
                        .value_taken = &self.value_taken,
                        .value = @ptrCast(self.value),
                        .fiber = self.fiber,
                    },
                },
            };
            channel.pending_operations.pushBack(&self.pending_operation);
            return .always_suspend;
        }

        pub fn awaitReady(_: *Self) bool {
            return false;
        }

        pub fn awaitResume(
            self: *Self,
            suspended: bool,
        ) void {
            if (suspended) {
                self.guard.lock();
            }
        }
    };
}

fn ReceiveAwaiter(T: type) type {
    return struct {
        const Self = @This();
        channel: *Channel(T),
        guard: *Spinlock.Guard,
        result: ?T = undefined,
        result_set: Atomic(bool) = .init(false),
        fiber: *Fiber = undefined,
        pending_operation: PendingOperation = undefined,

        pub fn awaiter(self: *Self) Awaiter {
            return Awaiter{
                .ptr = self,
                .vtable = .{
                    .await_suspend = awaitSuspend,
                },
            };
        }

        pub fn awaitSuspend(
            ctx: *anyopaque,
            handle: *anyopaque,
        ) Awaiter.AwaitSuspendResult {
            const self: *Self = @alignCast(@ptrCast(ctx));
            const fiber: *Fiber = @alignCast(@ptrCast(handle));
            self.fiber = fiber;
            const channel = self.channel;
            defer self.guard.unlock();
            if (channel.peekHead()) |head| {
                switch (head.operation) {
                    .send => |*send| {
                        if (self.result_set.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
                            assert(send.value_taken.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null);
                            defer _ = channel.pending_operations.popFront();
                            self.result = send.get(T);
                            log.debug("{*} will transfer to {s}", .{ self, send.fiber.name });
                            return .{ .symmetric_transfer_next = send.fiber };
                        } else unreachable;
                    },
                    .receive, .select_receive => {},
                }
            }
            self.pending_operation = .{
                .operation = .{
                    .receive = .{
                        .result_ptr = &self.result,
                        .fiber = self.fiber,
                        .result_set = &self.result_set,
                    },
                },
            };
            channel.pending_operations.pushBack(&self.pending_operation);
            return .always_suspend;
        }

        pub fn awaitReady(self: *Self) bool {
            if (self.channel.closed.load(.seq_cst)) {
                assert(self.result_set.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null);
                self.result = null;
                return true;
            }
            return false;
        }

        pub fn awaitResume(
            self: *Self,
            suspended: bool,
        ) void {
            if (suspended) {
                self.guard.lock();
            }
        }
    };
}

pub fn Channel(T: type) type {
    return struct {
        pub const ValueType = T;
        const Impl = @This();

        lock: Spinlock = .{},
        closed: Atomic(bool) = .init(false),
        pending_operations: Queue(PendingOperation) = .{},

        /// Parks fiber until rendezvous is finished and
        /// value is passed to another fiber which called `receive`.
        pub fn send(self: *Impl, value: T) void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            if (self.closed.load(.seq_cst)) {
                std.debug.panic("send on closed channel", .{});
            }
            var awaiter: SendAwaiter(T) = .{
                .value = &value,
                .channel = self,
                .guard = &guard,
            };
            Await(&awaiter);
            assert(awaiter.value_taken.load(.seq_cst));
        }

        /// Parks fiber until rendezvous is finished and
        /// value is received to another fiber which called `send`.
        pub fn receive(self: *Impl) ?T {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            var awaiter: ReceiveAwaiter(T) = .{
                .channel = self,
                .guard = &guard,
            };
            Await(&awaiter);
            assert(awaiter.result_set.load(.seq_cst));
            return awaiter.result;
        }

        pub const TryCloseError = error{
            already_closed,
        };

        pub fn tryClose(self: *Impl) TryCloseError!void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            if (self.closed.cmpxchgStrong(false, true, .seq_cst, .seq_cst)) |_| {
                return TryCloseError.already_closed;
            }
            var awaiter: CloseAwaiter = .{
                .channel = self,
                .guard = &guard,
            };
            Await(&awaiter);
        }

        pub fn close(self: *Impl) void {
            self.tryClose() catch
                std.debug.panic("closing an already closed channel", .{});
        }

        pub fn peekHead(self: *Impl) ?*PendingOperation {
            if (self.pending_operations.head) |head| {
                return head.parentPtr(PendingOperation);
            }
            return null;
        }

        const CloseAwaiter = struct {
            channel: *Impl,
            guard: *Spinlock.Guard,
            fiber: *Fiber = undefined,

            pub fn awaiter(self: *CloseAwaiter) Awaiter {
                return Awaiter{
                    .ptr = self,
                    .vtable = .{ .await_suspend = awaitSuspend },
                };
            }

            pub fn awaitReady(self: *CloseAwaiter) bool {
                if (self.channel.peekHead()) |head| {
                    const must_suspend = switch (head.operation) {
                        .receive, .select_receive => true,
                        else => false,
                    };
                    return !must_suspend;
                }
                return true;
            }

            pub fn awaitSuspend(
                ctx: *anyopaque,
                handle: *anyopaque,
            ) Awaiter.AwaitSuspendResult {
                const self: *CloseAwaiter = @alignCast(@ptrCast(ctx));
                const channel = self.channel;
                const fiber: *Fiber = @alignCast(@ptrCast(handle));
                self.fiber = fiber;
                const guard = self.guard;
                defer guard.unlock();
                while (channel.pending_operations.popFront()) |head| {
                    switch (head.operation) {
                        .receive => |receive_op| {
                            if (receive_op.trySet(T, null)) {
                                log.debug("{*} about to schedule receiver {*}", .{ self, fiber });
                                receive_op.fiber.scheduleSelf();
                            }
                        },
                        .select_receive => |select_receive_op| {
                            if (select_receive_op.trySet(T, null)) {
                                log.debug("{*} about to schedule select_receiver {*}", .{ self, fiber });
                                select_receive_op.fiber.scheduleSelf();
                            }
                        },
                        else => unreachable,
                    }
                }
                return .never_suspend;
            }

            pub fn awaitResume(self: *CloseAwaiter, suspended: bool) void {
                if (suspended) {
                    self.guard.lock();
                }
            }
        };
    };
}

test {
    _ = @import("./tests.zig");
    _ = select;
}
