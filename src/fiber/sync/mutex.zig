//! Mutual exclusion for fibers.
//! Locking does not block the underyling thread,
//! even for the contended case.
//! Instead, the contending fiber will be parked
//! until the mutex is unlocked.
//! Similar to `std.Thread.Mutex`
const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../root.zig");
const fault = cozi.fault;
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const log = cozi.core.log.scoped(.fiber_mutex);

const Fiber = cozi.Fiber;
const Await = cozi.@"await".@"await";
const Awaiter = cozi.@"await".Awaiter;
const Worker = cozi.@"await".Worker;

const containers = cozi.containers;
const Queue = containers.intrusive.lock_free.MpscQueue;

const Mutex = @This();

state: Atomic(State) align(std.atomic.cache_line) = .init(.unlocked),

// for fast path (no contention)
const State = enum(usize) {
    unlocked = 0,
    locked_no_awaiters = 1,
    // address of tail of of awaiting fibers,
    _,
};

fn StateFromNodePtr(node: *Node) State {
    return @enumFromInt(@intFromPtr(&node.intrusive_list_node));
}

fn NodePtrFromState(state: State) *Node {
    const intrusive_list_node: *containers.intrusive.Node =
        @ptrFromInt(@intFromEnum(state));

    return intrusive_list_node.parentPtr(Node);
}

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: containers.intrusive.Node = .{},

    pub fn getNext(self: *Node) ?*Node {
        if (self.intrusive_list_node.next) |next_intrusive_ptr| {
            return next_intrusive_ptr.parentPtr(Node);
        }
        return null;
    }

    pub fn setNext(self: *Node, next: ?*Node) void {
        const next_intrusive_ptr = if (next) |n| &n.intrusive_list_node else null;
        self.intrusive_list_node.next = next_intrusive_ptr;
    }
};

pub fn lock(self: *Mutex) void {
    if (Fiber.current()) |current_fiber| {
        log.debug("{s} about to attempt locking.", .{current_fiber.name});
        // store the awaiter on the Fiber stack
        var awaiter: LockAwaiter = .{
            .mutex = self,
        };
        // this is safe because Fiber.lock will not exit
        // during Fiber.await, so the stack will not be reused.
        Await(&awaiter);
        log.debug("{s} acquired lock.", .{current_fiber.name});
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

    // --- type-erased awaiter interface ---
    pub fn awaitSuspend(
        self: *@This(),
        worker: Worker,
    ) Awaiter.AwaitSuspendResult {
        const fiber: *Fiber = @alignCast(@ptrCast(worker.ptr));
        var mutex = self.mutex;
        self.queue_node = Node{
            .fiber = fiber,
        };
        const node: *Node = &self.queue_node;
        const self_as_enum = StateFromNodePtr(node);
        log.debug("{s} start lock loop", .{fiber.name});
        while (true) {
            switch (mutex.state.load(.seq_cst)) {
                .unlocked => {
                    log.debug("{s} saw .unlocked .", .{fiber.name});
                    // currently unlocked
                    // -> try to grab the lock
                    if (mutex.state.cmpxchgWeak(
                        .unlocked,
                        .locked_no_awaiters,
                        .seq_cst,
                        .seq_cst,
                    ) == null) {
                        log.debug("{s} acquired lock. Will proceed without suspending.", .{fiber.name});
                        // grabbed the lock
                        // -> can continue without suspending
                        return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
                    } else {
                        log.debug("{s} failed to acquire lock. Retry from top", .{fiber.name});
                        // somebody else grabbed the lock
                        // -> try again from top
                        continue;
                    }
                },
                .locked_no_awaiters => {
                    log.debug("{s} saw .locked_no_awaiters.", .{fiber.name});
                    // some fiber owns lock, but no other awaiters
                    // -> add self to stack as both tail & head
                    if (mutex.state.cmpxchgWeak(
                        .locked_no_awaiters,
                        self_as_enum,
                        .seq_cst,
                        .seq_cst,
                    ) == null) {
                        // we were the 1st to park in stack
                        log.debug("{s} registered self as tail", .{fiber.name});
                        break;
                    } else {
                        // somebody else registered themselves as tail
                        // try again from top
                        continue;
                    }
                },
                else => |tail_as_enum| {
                    const tail: *Node = NodePtrFromState(tail_as_enum);
                    log.debug(
                        "{s} saw {s} as previous tail",
                        .{ fiber.name, tail.fiber.name },
                    );
                    // some fiber owns lock, and there is at least
                    // 1 other fiber in the wait stack
                    // -> add ourselves to the tail of the stack
                    node.setNext(tail);
                    if (mutex.state.cmpxchgWeak(
                        tail_as_enum,
                        self_as_enum,
                        .seq_cst,
                        .seq_cst,
                    ) == null) {
                        log.debug(
                            "{s} registered self as new tail. Next -> {s}",
                            .{ fiber.name, tail.fiber.name },
                        );
                        // added selves as tail
                        // -> break & proceed in suspended state
                        break;
                    } else {
                        log.debug(
                            "{s} failed to register self as new tail. Retry from top.",
                            .{fiber.name},
                        );
                        node.setNext(null);
                        continue;
                    }
                },
            }
        }
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }

    pub fn awaiter(self: *LockAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{ .await_suspend = @ptrCast(&awaitSuspend) },
        };
    }

    // --- comptime awaiter interface ---
    pub fn awaitReady(self: *LockAwaiter) bool {
        // Fast path: no contention
        const acquired_lock = self.mutex.state.cmpxchgWeak(
            .unlocked,
            .locked_no_awaiters,
            .seq_cst,
            .seq_cst,
        ) == null;
        if (acquired_lock) {
            log.debug("Acquired lock in awaitReady -> no need to suspend.", .{});
        }
        return acquired_lock;
    }
    pub fn awaitResume(_: *LockAwaiter, _: bool) void {}
};

const UnlockAwaiter = struct {
    mutex: *Mutex,

    // --- type-erased awaiter interface ---
    pub fn awaitSuspend(
        self: *@This(),
        worker: Worker,
    ) Awaiter.AwaitSuspendResult {
        assert(worker.type == .fiber);
        const mutex = self.mutex;
        const fiber: *Fiber = @alignCast(@ptrCast(worker.ptr));

        log.debug("{s} start unlock loop", .{fiber.name});
        while (true) {
            switch (mutex.state.load(.seq_cst)) {
                .unlocked => {
                    // somebody else unlocked the mutex ??
                    std.debug.panic("{*}: Trying to unlock mutex {*} twice.", .{ self, mutex });
                },
                .locked_no_awaiters => {
                    log.debug("{s} saw .locked_no_awaiters", .{fiber.name});
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
                        log.debug("{s} successfully unlocked -> resume self", .{fiber.name});
                        return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
                    } else {
                        // somebody parked themselves in the wait stack
                        // -> retry from top
                        continue;
                    }
                },
                else => |tail_as_enum| {
                    const tail: *Node = NodePtrFromState(tail_as_enum);
                    log.debug(
                        "{s} saw {s} as tail",
                        .{ fiber.name, tail.fiber.name },
                    );
                    const maybe_next = tail.getNext();
                    if (maybe_next) |next| {
                        log.debug(
                            "{s} saw {s} next of tail. Will try to reach head",
                            .{ fiber.name, next.fiber.name },
                        );
                        var previous = tail;
                        var head = next;
                        while (head.getNext()) |n| : ({
                            log.debug(
                                "{s}: {s}->{s}",
                                .{ fiber.name, head.fiber.name, n.fiber.name },
                            );
                            previous = head;
                            head = n;
                        }) {}
                        log.debug(
                            "{s}: {s}.next->null",
                            .{ fiber.name, previous.fiber.name },
                        );
                        previous.setNext(null);
                        log.debug(
                            "symmetric transfer: {s} -> {s}",
                            .{ fiber.name, head.fiber.name },
                        );
                        return Awaiter.AwaitSuspendResult{
                            .symmetric_transfer_next = head.fiber,
                        };
                    } else {
                        log.debug("{s} saw tail.next == null", .{fiber.name});
                        // next was empty
                        if (mutex.state.cmpxchgWeak(
                            tail_as_enum,
                            .locked_no_awaiters,
                            .seq_cst,
                            .seq_cst,
                        ) == null) {
                            log.debug(
                                "symmetric transfer: {s} -> {s}",
                                .{ fiber.name, tail.fiber.name },
                            );
                            return Awaiter.AwaitSuspendResult{
                                .symmetric_transfer_next = tail.fiber,
                            };
                        }
                    }
                },
            }
        }
    }
    pub fn awaiter(self: *UnlockAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{ .await_suspend = @ptrCast(&awaitSuspend) },
        };
    }

    // --- comptime awaiter interface ---
    pub fn awaitReady(self: *UnlockAwaiter) bool {
        const mutex = self.mutex;
        // fast path: nobody else is waiting
        const released_lock = mutex.state.cmpxchgWeak(
            .locked_no_awaiters,
            .unlocked,
            .seq_cst,
            .seq_cst,
        ) == null;
        if (released_lock) {
            log.debug("Released lock in awaitReady -> no need to suspend.", .{});
        }
        return released_lock;
    }

    pub fn awaitResume(_: *UnlockAwaiter, _: bool) void {}
};

test {
    _ = @import("./mutex/tests.zig");
}
