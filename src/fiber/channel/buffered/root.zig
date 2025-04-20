const std = @import("std");
const log = std.log.scoped(.fiber_buffered_channel);
const assert = std.debug.assert;
const fault = @import("../../../fault/root.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const GenericAwait = @import("../../../await/root.zig");
const Awaiter = GenericAwait.Awaiter;
const Await = GenericAwait.@"await";

const Containers = @import("../../../containers/root.zig");
const Queue = Containers.Intrusive.ForwardList;
const Node = Containers.Intrusive.Node;

const Spinlock = @import("../../../sync/root.zig").Spinlock;
const Fiber = @import("../../root.zig");

pub fn BufferedChannel(T: type) type {
    return struct {
        const Impl = @This();

        buffer: BufferType,

        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        closed: bool = false,

        lock: Spinlock = .{},
        parked_receivers: Queue(ReceiveAwaiter) = .{},
        parked_senders: Queue(SendAwaiter) = .{},

        pub const BufferType = []T;

        /// If buffer is full, parks fiber until
        /// a value is received by another fiber.
        pub fn send(self: *Impl, value: T) void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            if (self.closed) {
                std.debug.panic("send on closed channel", .{});
            }
            var awaiter: SendAwaiter = .{
                .channel = self,
                .guard = &guard,
                .value = &value,
            };
            Await(&awaiter);
        }

        /// If buffer is empty, parks fiber until
        /// a value is sent from another fiber.
        pub fn receive(self: *Impl) ?T {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            var awaiter: ReceiveAwaiter = .{
                .channel = self,
                .guard = &guard,
                .result = undefined,
            };
            const result = Await(&awaiter);
            log.debug("recv: about to return {?}", .{result});
            return result;
        }

        inline fn isFull(self: *Impl) bool {
            return self.count > 0 and self.head == self.tail;
        }

        inline fn isEmpty(self: *Impl) bool {
            return self.count == 0 and self.head == self.tail;
        }

        fn pushHead(self: *Impl, value: T) void {
            defer {
                const old_head = self.head;
                self.head += 1;
                if (self.head == self.buffer.len) {
                    self.head = 0;
                }
                const old_count = self.count;
                self.count += 1;
                log.debug(
                    "Pushed {}. Head: {}->{}. Count: {}->{}",
                    .{
                        value,
                        old_head,
                        self.head,
                        old_count,
                        self.count,
                    },
                );
            }
            self.buffer[self.head] = value;
        }

        fn popTail(self: *Impl) T {
            defer {
                const old_tail = self.tail;
                self.tail += 1;
                if (self.tail == self.buffer.len) {
                    self.tail = 0;
                }
                const old_count = self.count;
                self.count -= 1;
                log.debug(
                    "Popping value {}. Tail: {}->{}. Count: {}->{}",
                    .{
                        self.buffer[old_tail],
                        old_tail,
                        self.tail,
                        old_count,
                        self.count,
                    },
                );
            }
            return self.buffer[self.tail];
        }

        pub fn close(self: *Impl) void {
            var guard = self.lock.guard();
            guard.lock();
            defer guard.unlock();
            self.closed = true;
            var awaiter: CloseAwaiter = .{
                .channel = self,
                .guard = &guard,
            };
            Await(&awaiter);
        }

        const SendAwaiter = struct {
            channel: *Impl,
            guard: *Spinlock.Guard,
            value: *const T,
            fiber: *Fiber = undefined,
            intrusive_list_node: Node = .{},

            pub fn awaiter(self: *SendAwaiter) Awaiter {
                return Awaiter{
                    .ptr = self,
                    .vtable = .{ .await_suspend = awaitSuspend },
                };
            }

            pub fn awaitReady(self: *SendAwaiter) bool {
                const channel = self.channel;
                if (channel.isFull()) {
                    return false;
                }
                if (!channel.parked_receivers.isEmpty()) {
                    return false;
                }
                channel.pushHead(self.value.*);
                return true;
            }

            pub fn awaitSuspend(
                ctx: *anyopaque,
                handle: *anyopaque,
            ) Awaiter.AwaitSuspendResult {
                const self: *SendAwaiter = @alignCast(@ptrCast(ctx));
                const channel = self.channel;
                const fiber: *Fiber = @alignCast(@ptrCast(handle));
                self.fiber = fiber;
                const guard = self.guard;
                if (channel.isFull()) {
                    assert(channel.parked_receivers.isEmpty());
                    defer guard.unlock();
                    channel.parked_senders.pushBack(self);
                    return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
                }
                if (channel.parked_receivers.popFront()) |receiver| {
                    defer guard.unlock();
                    assert(channel.isEmpty());
                    receiver.result = self.value.*;
                    return Awaiter.AwaitSuspendResult{
                        .symmetric_transfer_next = receiver.fiber,
                    };
                } else unreachable;
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
            intrusive_list_node: Node = .{},
            fiber: *Fiber = undefined,
            result: ?T = undefined,

            pub fn awaiter(self: *ReceiveAwaiter) Awaiter {
                return Awaiter{
                    .ptr = self,
                    .vtable = .{ .await_suspend = awaitSuspend },
                };
            }

            pub fn awaitReady(self: *ReceiveAwaiter) bool {
                const channel = self.channel;
                if (channel.isEmpty()) {
                    if (channel.closed) {
                        self.result = null;
                        return true;
                    }
                    return false;
                }
                if (!channel.parked_senders.isEmpty()) {
                    return false;
                }
                self.result = channel.popTail();
                return true;
            }

            pub fn awaitSuspend(
                ctx: *anyopaque,
                handle: *anyopaque,
            ) Awaiter.AwaitSuspendResult {
                const self: *ReceiveAwaiter = @alignCast(@ptrCast(ctx));
                const channel = self.channel;
                const fiber: *Fiber = @alignCast(@ptrCast(handle));
                self.fiber = fiber;
                const guard = self.guard;
                if (channel.isEmpty()) {
                    assert(channel.parked_senders.isEmpty());
                    defer guard.unlock();
                    channel.parked_receivers.pushBack(self);
                    return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
                }
                if (channel.parked_senders.popFront()) |sender| {
                    defer guard.unlock();
                    assert(channel.isFull());
                    self.result = channel.popTail();
                    assert(!channel.isFull());
                    channel.pushHead(sender.value.*);
                    return Awaiter.AwaitSuspendResult{
                        .symmetric_transfer_next = sender.fiber,
                    };
                } else {
                    unreachable;
                }
            }

            pub fn awaitResume(
                self: *ReceiveAwaiter,
                suspended: bool,
            ) ?T {
                if (suspended) {
                    self.guard.lock();
                }
                return self.result;
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
                const channel = self.channel;
                if (!channel.parked_receivers.isEmpty()) {
                    return false;
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
                if (channel.parked_receivers.popFront()) |receiver| {
                    defer guard.unlock();
                    assert(channel.isEmpty());
                    receiver.result = null;
                    return Awaiter.AwaitSuspendResult{
                        .symmetric_transfer_next = receiver.fiber,
                    };
                } else unreachable;
            }

            pub fn awaitResume(self: *CloseAwaiter, suspended: bool) void {
                if (suspended) {
                    self.guard.lock();
                }
            }
        };

        pub const Managed = struct {
            allocator: std.mem.Allocator,
            raw: Impl,

            const Self = @This();

            pub fn init(
                capacity: usize,
                allocator: std.mem.Allocator,
            ) !@This() {
                const buffer: Impl.BufferType = try allocator.alloc(T, capacity);
                return .{ .allocator = allocator, .raw = .{ .buffer = buffer } };
            }

            pub fn deinit(self: *Self) void {
                self.allocator.free(self.raw.buffer);
                self.raw = undefined;
                self.allocator = undefined;
            }

            pub inline fn send(self: *Self, value: T) void {
                return self.raw.send(value);
            }

            pub inline fn receive(self: *Self) ?T {
                return self.raw.receive();
            }

            pub inline fn close(self: *Self) void {
                return self.raw.close();
            }
        };
    };
}

test {
    _ = @import("./tests.zig");
}
