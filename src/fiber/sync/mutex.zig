//! Mutual exclusion for fibers.
//! Locking does not block the underyling thread,
//! even for the contended case.
//! Instead, the contending fiber will be parked
//! until the mutex is unlocked.
const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

const Mutex = @This();

const Fiber = @import("../../fiber.zig");
const Awaiter = @import("../../awaiter.zig");
const Containers = @import("../../containers.zig");
const Queue = Containers.Intrusive.LockFree.MpscQueue;
const Await = @import("../../await.zig").@"await";

// for fast path (no contention)
const State = enum(usize) {
    unlocked = 0,
    locked_no_awaiters = 1,
    // address of tail of of awaiting fibers,
    _,
};

// also, tail
state: Atomic(State) align(std.atomic.cache_line) = .init(.unlocked),
head: Atomic(?*Node) align(std.atomic.cache_line) = .init(null),

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: Containers.Intrusive.Node = .{},
};

pub fn lock(self: *Mutex) void {
    if (Fiber.current()) |current_fiber| {
        // store the awaiter on the Fiber stack
        var awaiter: LockAwaiter = .{
            .mutex = self,
        };
        // this is safe because Fiber.lock will not exit
        // during Fiber.await, so the stack will not be reused.
        Await(&awaiter);
        current_fiber.beginSuspendIllegalScope();
    } else {
        std.debug.panic("Fiber.Mutex.lock can only be called while executing inside of a fiber.", .{});
    }
}

pub fn tryLock(self: *Mutex) bool {
    if (Fiber.current()) |current_fiber| {
        const acquired_lock = self.state.cmpxchgStrong(
            .unlocked,
            .locked_no_awaiters,
            .seq_cst,
            .seq_cst,
        ) == null;
        if (acquired_lock) {
            current_fiber.beginSuspendIllegalScope();
            return true;
        }
        return false;
    } else {
        std.debug.panic("Fiber.Mutex.tryLock can only be called while executing inside of a fiber.", .{});
    }
}

pub fn unlock(self: *Mutex) void {
    if (Fiber.current()) |current_fiber| {
        current_fiber.endSuspendIllegalScope();
        var awaiter: UnlockAwaiter = .{ .mutex = self };
        Await(&awaiter);
    } else {
        std.debug.panic("Fiber.Mutex.lock can only be called while executing inside of a fiber.", .{});
    }
}

const LockAwaiter = struct {
    mutex: *Mutex,
    queue_node: Node = undefined,

    pub fn awaiter(self: *LockAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = awaitSuspend,
                .await_resume = awaitResume,
                .await_ready = awaitReady,
            },
        };
    }

    pub fn awaitResume(_: *anyopaque) void {}

    pub fn awaitReady(ctx: *anyopaque) bool {
        var self: *LockAwaiter = @alignCast(@ptrCast(ctx));
        // Fast path: no contention
        const acquired_lock = self.mutex.state.cmpxchgWeak(
            .unlocked,
            .locked_no_awaiters,
            .seq_cst,
            .seq_cst,
        ) == null;
        return acquired_lock;
    }

    pub fn awaitSuspend(
        ctx: *anyopaque,
        handle: *anyopaque,
    ) Awaiter.AwaitSuspendResult {
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        var self: *LockAwaiter = @alignCast(@ptrCast(ctx));
        var mutex = self.mutex;
        self.queue_node = .{
            .fiber = fiber,
        };
        const self_as_enum: State = @enumFromInt(@intFromPtr(&self.queue_node));
        const node: *Node = &self.queue_node;
        while (true) {
            switch (mutex.state.load(.seq_cst)) {
                .unlocked => {
                    // currently unlocked
                    // -> try to grab the lock
                    if (mutex.state.cmpxchgWeak(
                        .unlocked,
                        .locked_no_awaiters,
                        .seq_cst,
                        .seq_cst,
                    ) == null) {
                        // grabbed the lock
                        // -> can continue without suspending
                        return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
                    } else {
                        // somebody else grabbed the lock
                        // -> try again from top
                        continue;
                    }
                },
                .locked_no_awaiters => {
                    // some fiber owns lock, but no other awaiters
                    // -> add self to stack as both tail & head
                    if (mutex.state.cmpxchgWeak(
                        .locked_no_awaiters,
                        self_as_enum,
                        .seq_cst,
                        .seq_cst,
                    ) == null) {
                        // we were the 1st to park in stack
                        if (mutex.head.cmpxchgStrong(
                            null,
                            node,
                            .seq_cst,
                            .seq_cst,
                        )) |head| {
                            if (head == node) {
                                // another fiber helped us
                                break;
                            } else unreachable;
                        } else {
                            break;
                        }
                    } else {
                        // somebody else registered themselves as tail
                        // try again from top
                        continue;
                    }
                },
                else => |tail_as_enum| {
                    const tail: *Node = @ptrFromInt(@intFromEnum(tail_as_enum));
                    // some fiber owns lock, and there is at least
                    // 1 other fiber in the wait stack
                    // -> add ourselves to the head of the stack
                    if (mutex.head.load(.seq_cst)) |old_head| {
                        node.intrusive_list_node.next = &old_head.intrusive_list_node;
                        if (mutex.head.cmpxchgWeak(
                            old_head,
                            node,
                            .seq_cst,
                            .seq_cst,
                        ) == null) {
                            // succeded in adding ourselves as the head
                            // -> suspend
                            break;
                        } else {
                            // somebody else registered themselves as head
                            // -> clean up & retry from top
                            node.intrusive_list_node.next = null;
                            continue;
                        }
                    } else {
                        // old_head == null, meaning that
                        // tail has not registered itself as head yet
                        // -> let's try helping them, and then
                        //    retry from the top
                        _ = mutex.head.cmpxchgStrong(
                            null,
                            tail,
                            .seq_cst,
                            .seq_cst,
                        );
                        continue;
                    }
                },
            }
        }
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }
};

const UnlockAwaiter = struct {
    mutex: *Mutex,

    pub fn awaiter(self: *UnlockAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = awaitSuspend,
                .await_resume = awaitResume,
                .await_ready = awaitReady,
            },
        };
    }

    pub fn awaitResume(_: *anyopaque) void {}

    pub fn awaitReady(ctx: *anyopaque) bool {
        const self: *UnlockAwaiter = @alignCast(@ptrCast(ctx));
        const mutex = self.mutex;
        // fast path: nobody else is waiting
        const released_lock = mutex.state.cmpxchgWeak(
            .locked_no_awaiters,
            .unlocked,
            .seq_cst,
            .seq_cst,
        ) == null;
        return released_lock;
    }

    pub fn awaitSuspend(
        ctx: *anyopaque,
        handle: *anyopaque,
    ) Awaiter.AwaitSuspendResult {
        const self: *UnlockAwaiter = @alignCast(@ptrCast(ctx));
        const mutex = self.mutex;
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        while (true) {
            switch (mutex.state.load(.seq_cst)) {
                .unlocked => {
                    // somebody else unlocked the mutex ??
                    std.debug.panic("{*}: Trying to unlock mutex {*} twice.", .{ self, mutex });
                },
                .locked_no_awaiters => {
                    // fast path: we hold the lock,
                    // and nobody else is waiting
                    if (mutex.state.cmpxchgWeak(
                        .locked_no_awaiters,
                        .unlocked,
                        .seq_cst,
                        .seq_cst,
                    ) == null) {
                        // unlocked successfully
                        // -> no need to suspend
                        return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
                    } else {
                        // somebody parked themselves in the wait stack
                        // -> retry from top
                        continue;
                    }
                },
                else => |tail_as_enum| {
                    const tail: *Node = @ptrFromInt(@intFromEnum(tail_as_enum));
                    if (mutex.head.load(.seq_cst)) |old_head| {
                        const next: ?*Node =
                            if (old_head.intrusive_list_node.next) |n|
                            @fieldParentPtr("intrusive_list_node", n)
                        else
                            null;
                        if (mutex.head.cmpxchgWeak(
                            old_head,
                            next,
                            .seq_cst,
                            .seq_cst,
                        ) == null) {
                            if (next == null) {
                                assert(old_head == tail);
                                assert(mutex.state.swap(.locked_no_awaiters, .seq_cst) == tail_as_enum);
                            }
                            // symmetric transfer to head
                            fiber.@"resume"();
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = old_head.fiber,
                            };
                        } else {
                            // new thread parked at the head
                            // retry from top
                            continue;
                        }
                    } else {
                        // tail exists, but head == null
                        // try to help tail
                        _ = mutex.head.cmpxchgWeak(
                            null,
                            tail,
                            .seq_cst,
                            .seq_cst,
                        );
                        continue;
                    }
                },
            }
        }
    }
};

test {
    _ = @import("./mutex/tests.zig");
}
