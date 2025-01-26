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

pub const SelectError = error{
    not_ready,
};

pub fn Channellike(T: type) type {
    return struct {
        const Self = @This();
        ptr: *anyopaque,
        vtable: struct {
            send: *const fn (ctx: *anyopaque, value: T) void,
            receive: *const fn (ctx: *anyopaque) ?T,
            selectReceive: *const fn (ctx: *anyopaque) SelectError!?T,
        },

        pub inline fn send(self: *Self, value: T) void {
            return self.vtable.send(self.ptr, value);
        }

        pub inline fn receive(self: *Self) ?T {
            return self.vtable.receive(self.ptr);
        }

        pub inline fn selectReceive(self: *Self) !?T {
            return self.vtable.selectReceive(self.ptr);
        }
    };
}

pub fn QueueElement(T: type) type {
    return struct {
        const Self = @This();
        pub const WaitingFiber = union(enum) {
            sender: SendAwaiter(T),
            receiver: ReceiveAwaiter(T),

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

        pub inline fn awaiter(self: *Self) Awaiter {
            return self.waiting_fiber.awaiter();
        }

        pub inline fn awaitReady(self: *Self) bool {
            return self.waiting_fiber.awaitReady();
        }

        pub inline fn awaitResume(
            self: *Self,
            suspended: bool,
        ) void {
            return self.waiting_fiber.awaitResume(suspended);
        }

        fn fromAwaiter(ptr: anytype) *Self {
            const type_info: std.builtin.Type.Pointer = @typeInfo(@TypeOf(ptr)).pointer;
            const name = switch (type_info.child) {
                SendAwaiter(T) => "sender",
                ReceiveAwaiter(T) => "receiver",
                else => @compileError(std.fmt.comptimePrint(
                    "Invalid ptr type: {s}",
                    @typeName(type_info.child),
                )),
            };
            const waiting_fiber: *WaitingFiber = @fieldParentPtr(name, ptr);
            return @fieldParentPtr("waiting_fiber", waiting_fiber);
        }
    };
}

fn SendAwaiter(T: type) type {
    return struct {
        const Self = @This();
        channel: *Channel(T),
        guard: *Spinlock.Guard,
        value: *const T,
        fiber: *Fiber = undefined,

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
            if (channel.operation_queue.head) |head| {
                const queue_element: *QueueElement(T) = head.parentPtr(QueueElement(T));
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
            channel.operation_queue.pushBack(QueueElement(T).fromAwaiter(self));
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
            if (channel.operation_queue.head) |head| {
                const element: *QueueElement(T) = head.parentPtr(QueueElement(T));
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
            channel.operation_queue.pushBack(QueueElement(T).fromAwaiter(self));
            return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
        }

        pub fn awaitReady(self: *Self) bool {
            if (self.channel.closed) {
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
        closed: bool = false,
        operation_queue: Queue(QueueElement(T)) = .{},

        /// Parks fiber until rendezvous is finished and
        /// value is passed to another fiber which called `receive`.
        pub fn send(self: *Impl, value: T) void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            if (self.closed) {
                std.debug.panic("send on closed channel", .{});
            }
            var queue_element: QueueElement(T) = .{
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
            var queue_element: QueueElement(T) = .{
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

        pub fn selectReceive(_: *Impl) SelectError!?T {
            return null;
        }

        pub fn asChannellike(self: *Impl) Channellike(T) {
            const InterfaceImpl = struct {
                pub fn send(ctx: *anyopaque, value: T) void {
                    const self_: *Impl = @alignCast(@ptrCast(ctx));
                    return self_.send(value);
                }

                pub fn receive(ctx: *anyopaque) ?T {
                    const self_: *Impl = @alignCast(@ptrCast(ctx));
                    return self_.receive();
                }

                pub fn selectReceive(ctx: *anyopaque) SelectError!?T {
                    const self_: *Impl = @alignCast(@ptrCast(ctx));
                    return self_.selectReceive();
                }
            };
            return Channellike(T){
                .ptr = self,
                .vtable = .{
                    .send = InterfaceImpl.send,
                    .receive = InterfaceImpl.receive,
                    .selectReceive = InterfaceImpl.selectReceive,
                },
            };
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
                if (self.channel.operation_queue.head) |head| {
                    const must_suspend = head.parentPtr(QueueElement(T)).waiting_fiber == .receiver;
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
    _ = @import("./tests.zig");
    _ = BufferedChannel;
    _ = select;
}
