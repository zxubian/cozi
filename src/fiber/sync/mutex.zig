//! Mutual exclusion for fibers.
//! Locking does not block the underyling thread,
//! even for the contended case.
//! Instead, the contending fiber will be parked
//! until the mutex is unlocked.
const std = @import("std");
const Atomic = std.atomic.Value;

const Mutex = @This();

const Fiber = @import("../../fiber.zig");
const Awaiter = @import("../../awaiter.zig");
const Containers = @import("../../containers.zig");
const Queue = Containers.Intrusive.LockFree.MpscQueue;
const Await = @import("../../await.zig").@"await";

const log = std.log.scoped(.fiber_mutex);

// for fast path (no contention)
locked: Atomic(bool) = .init(false),
queue: Queue(Node) = .{},

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: Containers.Intrusive.Node = .{},
};

pub fn lock(self: *Mutex) void {
    if (!Fiber.isInFiber()) {
        std.debug.panic("Fiber.Mutex.lock can only be called while executing inside of a fiber.", .{});
    }
    // store the awaiter on the Fiber stack
    var awaiter: MutexAwaiter = .{
        .mutex = self,
    };
    // this is safe because Fiber.lock will not exit
    // during Fiber.await, so the stack will not be reused.
    Await(&awaiter);
}

pub fn tryLock(self: *Mutex) bool {
    if (!Fiber.isInFiber()) {
        std.debug.panic("Fiber.Mutex.tryLock can only be called while executing inside of a fiber.", .{});
    }
    return self.locked.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null;
}

pub fn unlock(self: *Mutex) void {
    if (!Fiber.isInFiber()) {
        std.debug.panic("Fiber.Mutex.lock can only be called while executing inside of a fiber.", .{});
    }
    log.info("{s} unlocking mutex ({*})", .{ Fiber.current().?.name, self });
    if (self.queue.popFront()) |next| {
        log.info("{s} scheduling next fiber from {*} waitqueue: {s}", .{
            Fiber.current().?.name,
            self,
            next.fiber.name,
        });
        next.fiber.scheduleSelf();
    } else {
        log.info("{s} saw empty waitqueue when unlocking mutex ({*})", .{
            Fiber.current().?.name,
            self,
        });
        self.locked.store(false, .seq_cst);
    }
}

const MutexAwaiter = struct {
    mutex: *Mutex,
    queue_node: Node = undefined,

    pub fn awaiter(self: *MutexAwaiter) Awaiter {
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
        var self: *MutexAwaiter = @alignCast(@ptrCast(ctx));
        // Fast path: no contention
        return self.mutex.locked.cmpxchgStrong(
            false,
            true,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    pub fn awaitSuspend(ctx: *anyopaque, handle: *anyopaque) bool {
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        var self: *MutexAwaiter = @alignCast(@ptrCast(ctx));
        if (self.mutex.locked.cmpxchgStrong(
            false,
            true,
            .seq_cst,
            .seq_cst,
        ) == null) {
            return true;
        }
        log.info("{s} parking itself in {*} waitqueue", .{
            fiber.name,
            self,
        });
        self.queue_node = .{
            .fiber = fiber,
        };
        self.mutex.queue.pushBack(&self.queue_node);
        return false;
    }
};

test {
    _ = @import("./mutex/tests.zig");
}
