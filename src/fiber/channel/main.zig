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

pub fn Channel(T: type) type {
    return struct {
        pub const Buffered = BufferedChannel(T);
        const Impl = @This();

        lock: Spinlock = .{},
        closed: bool = false,
        operation_queue: Queue(QueueElement) = .{},

        /// Parks fiber until rendezvous is finished and
        /// value is passed to another fiber which called `receive`.
        pub fn send(self: *Impl, value: T) void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            if (self.closed) {
                std.debug.panic("send on closed channel", .{});
            }
            var queue_element: QueueElement = .{
                .waiting_fiber = .{
                    .sender = .{
                        .value = &value,
                        .channel = self,
                        .guard = &guard,
                    },
                },
            };
            Await(&queue_element);
        }

        /// Parks fiber until rendezvous is finished and
        /// value is received to another fiber which called `send`.
        pub fn receive(self: *Impl) ?T {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            var queue_element: QueueElement = .{
                .waiting_fiber = .{
                    .receiver = .{
                        .channel = self,
                        .guard = &guard,
                    },
                },
            };
            Await(&queue_element);
            return queue_element.waiting_fiber.receiver.result;
        }

        pub fn close(self: *Impl) void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            if (self.closed) {
                std.debug.panic("closing an already closed channel", .{});
            }
            self.closed = true;
            var awaiter: CloseAwaiter = .{
                .channel = self,
                .guard = &guard,
            };
            Await(&awaiter);
        }

        const QueueElement = struct {
            pub const WaitingFiber = union(enum) {
                sender: SendAwaiter,
                receiver: ReceiveAwaiter,

                pub inline fn awaiter(self: *WaitingFiber) Awaiter {
                    return switch (self.*) {
                        .sender => |*sender| sender.awaiter(),
                        .receiver => |*receiver| receiver.awaiter(),
                    };
                }

                pub inline fn awaitReady(self: *WaitingFiber) bool {
                    return switch (self.*) {
                        .sender => |*sender| sender.awaitReady(),
                        .receiver => |*receiver| receiver.awaitReady(),
                    };
                }

                pub inline fn awaitResume(self: *WaitingFiber, suspended: bool) void {
                    return switch (self.*) {
                        .sender => |*sender| sender.awaitResume(suspended),
                        .receiver => |*receiver| receiver.awaitResume(suspended),
                    };
                }
            };

            intrusive_list_node: Node = .{},
            waiting_fiber: WaitingFiber,

            pub inline fn awaiter(self: *QueueElement) Awaiter {
                return self.waiting_fiber.awaiter();
            }

            pub inline fn awaitReady(self: *QueueElement) bool {
                return self.waiting_fiber.awaitReady();
            }

            pub inline fn awaitResume(
                self: *QueueElement,
                suspended: bool,
            ) void {
                return self.waiting_fiber.awaitResume(suspended);
            }

            fn fromAwaiter(ptr: anytype) *QueueElement {
                const type_info: std.builtin.Type.Pointer = @typeInfo(@TypeOf(ptr)).pointer;
                const name = switch (type_info.child) {
                    SendAwaiter => "sender",
                    ReceiveAwaiter => "receiver",
                    else => @compileError(std.fmt.comptimePrint(
                        "Invalid ptr type: {s}",
                        @typeName(type_info.child),
                    )),
                };
                const waiting_fiber: *WaitingFiber = @fieldParentPtr(name, ptr);
                return @fieldParentPtr("waiting_fiber", waiting_fiber);
            }
        };

        const SendAwaiter = struct {
            channel: *Impl,
            guard: *Spinlock.Guard,
            value: *const T,
            fiber: *Fiber = undefined,

            pub fn awaiter(self: *SendAwaiter) Awaiter {
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
                const self: *SendAwaiter = @alignCast(@ptrCast(ctx));
                const fiber: *Fiber = @alignCast(@ptrCast(handle));
                self.fiber = fiber;
                defer self.guard.unlock();
                const channel = self.channel;
                if (channel.operation_queue.head) |head| {
                    const queue_element: *QueueElement = head.parentPtr(QueueElement);
                    switch (queue_element.waiting_fiber) {
                        .sender => {},
                        .receiver => |*receiver| {
                            defer _ = channel.operation_queue.popFront();
                            receiver.result = self.value.*;
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = receiver.fiber,
                            };
                        },
                    }
                }
                channel.operation_queue.pushBack(QueueElement.fromAwaiter(self));
                return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
            }

            pub fn awaitReady(_: *SendAwaiter) bool {
                return false;
            }

            pub fn awaitResume(
                self: *SendAwaiter,
                suspended: bool,
            ) void {
                if (suspended) {
                    self.guard.lock();
                }
            }
        };

        const ReceiveAwaiter = struct {
            channel: *Impl,
            guard: *Spinlock.Guard,
            result: ?T = undefined,
            fiber: *Fiber = undefined,

            pub fn awaiter(self: *ReceiveAwaiter) Awaiter {
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
                const self: *ReceiveAwaiter = @alignCast(@ptrCast(ctx));
                const fiber: *Fiber = @alignCast(@ptrCast(handle));
                self.fiber = fiber;
                const channel = self.channel;
                defer self.guard.unlock();
                if (channel.operation_queue.head) |head| {
                    const element: *QueueElement = head.parentPtr(QueueElement);
                    switch (element.waiting_fiber) {
                        .sender => |sender| {
                            defer _ = channel.operation_queue.popFront();
                            self.result = sender.value.*;
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = sender.fiber,
                            };
                        },
                        .receiver => {},
                    }
                }
                channel.operation_queue.pushBack(QueueElement.fromAwaiter(self));
                return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
            }

            pub fn awaitReady(self: *ReceiveAwaiter) bool {
                if (self.channel.closed) {
                    self.result = null;
                    return true;
                }
                return false;
            }

            pub fn awaitResume(
                self: *ReceiveAwaiter,
                suspended: bool,
            ) void {
                if (suspended) {
                    self.guard.lock();
                }
            }
        };

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
                if (self.channel.operation_queue.head) |head| {
                    const must_suspend = head.parentPtr(QueueElement).waiting_fiber == .receiver;
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
                while (channel.operation_queue.popFront()) |head| {
                    const receiver = &head.waiting_fiber.receiver;
                    receiver.result = null;
                    receiver.fiber.scheduleSelf();
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
    _ = BufferedChannel;
    _ = @import("./tests.zig");
}
