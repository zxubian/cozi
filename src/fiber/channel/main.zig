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

const BufferedChannel = @import("./buffered/main.zig").BufferedChannel;

const select_ = @import("./select/main.zig");
pub const select = select_.select;
const SelectAwaiter = select_.SelectAwaiter;

pub fn QueueElement(T: type) type {
    return struct {
        const Self = @This();
        pub const Operation = union(enum) {
            send: struct {
                pub fn awaiter(self: *@This()) *SendAwaiter(T) {
                    const operation: *Operation = @alignCast(@fieldParentPtr("send", self));
                    const queue_element: *Self = @alignCast(@fieldParentPtr("operation", operation));
                    return @alignCast(@fieldParentPtr("queue_element", queue_element));
                }
            },
            receive: struct {
                pub fn awaiter(self: *@This()) *ReceiveAwaiter(T) {
                    const operation: *Operation = @alignCast(@fieldParentPtr("receive", self));
                    const queue_element: *Self = @alignCast(@fieldParentPtr("operation", operation));
                    return @alignCast(@fieldParentPtr("queue_element", queue_element));
                }
            },
            select_receive: *SelectAwaiter(T),
        };
        intrusive_list_node: Node = .{},
        operation: Operation,
    };
}

fn SendAwaiter(T: type) type {
    return struct {
        const Self = @This();
        channel: *Channel(T),
        guard: *Spinlock.Guard,
        value: *const T,
        fiber: *Fiber = undefined,
        queue_element: QueueElement(T),

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
                        defer _ = channel.parked_fibers.popFront();
                        const receiver = receive.awaiter();
                        receiver.result = self.value.*;
                        return Awaiter.AwaitSuspendResult{
                            .symmetric_transfer_next = receiver.fiber,
                        };
                    },
                    .select_receive => |receiver| {
                        if (receiver.result_set.cmpxchgStrong(
                            false,
                            true,
                            .seq_cst,
                            .seq_cst,
                        ) == null) {
                            defer _ = channel.parked_fibers.popFront();
                            receiver.*.result = .{
                                .channel_index = receiver.findChannelIndex(channel).?,
                                .value = self.value.*,
                            };
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = receiver.fiber,
                            };
                        }
                    },
                }
            }
            log.debug("{*}: will suspend", .{self});
            channel.parked_fibers.pushBack(&self.queue_element);
            return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
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
        fiber: *Fiber = undefined,
        queue_element: QueueElement(T),

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
                        defer _ = channel.parked_fibers.popFront();
                        const sender = send.awaiter();
                        self.result = sender.value.*;
                        return Awaiter.AwaitSuspendResult{
                            .symmetric_transfer_next = sender.fiber,
                        };
                    },
                    .receive, .select_receive => {},
                }
            }
            channel.parked_fibers.pushBack(&self.queue_element);
            return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
        }

        pub fn awaitReady(self: *Self) bool {
            if (self.channel.closed.load(.seq_cst)) {
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
        pub const Buffered = BufferedChannel(T);
        const Impl = @This();

        lock: Spinlock = .{},
        closed: Atomic(bool) = .init(false),
        parked_fibers: Queue(QueueElement(T)) = .{},

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
                .queue_element = .{
                    .operation = .send,
                },
            };
            Await(&awaiter);
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
                .queue_element = .{
                    .operation = .receive,
                },
            };
            Await(&awaiter);
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

        pub fn peekHead(self: *Impl) ?*QueueElement(T) {
            if (self.parked_fibers.head) |head| {
                return head.parentPtr(QueueElement(T));
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
                while (channel.parked_fibers.popFront()) |head| {
                    switch (head.operation) {
                        .receive => |*receive_op| {
                            const receiver = receive_op.awaiter();
                            receiver.result = null;
                            receiver.fiber.scheduleSelf();
                        },
                        .select_receive => |selector| {
                            if (selector.result_set.cmpxchgStrong(
                                false,
                                true,
                                .seq_cst,
                                .seq_cst,
                            )) |_| {
                                continue;
                            }
                            selector.result = .{
                                .channel_index = selector.findChannelIndex(channel).?,
                                .value = null,
                            };
                            selector.fiber.scheduleSelf();
                        },
                        else => unreachable,
                    }
                }
                return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
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
    _ = BufferedChannel;
    _ = select;
}
