//! Mutual exclusion for fibers.
//! Locking does not block the underyling thread,
//! even for the contended case.
//! Instead, the contending fiber will be parked
//! until the mutex is unlocked.
const std = @import("std");
const Atomic = std.atomic.Value;

const Mutex = @This();

const Fiber = @import("../fiber.zig");
const Awaiter = @import("./awaiter.zig");
const Spinlock = @import("../sync.zig").Spinlock;
const ForwardList = @import("../containers.zig").Intrusive.ForwardList;
const Queue = ForwardList.IntrusiveForwardList;

const log = std.log.scoped(.fiber_mutex);

// for fast path (no contention)
locked: Atomic(bool) = .init(false),
/// protects queue
mutex: Spinlock = .{},
// protected by mutex
queue: Queue(Node) = .{},

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: ForwardList.Node = .{},
};

pub fn lock(self: *Mutex) void {
    if (!Fiber.isInFiber()) {
        std.debug.panic("Fiber.Mutex.lock can only be called while executing inside of a fiber.", .{});
    }
    // Fast path: no contention
    if (self.locked.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
        return;
    }
    // Mutex already owned by another fiber
    // store the awaiter on the Fiber stack
    var awaiter: MutexAwaiter = .{
        .mutex = self,
        .awaiter = .{
            .vtable = .{
                .@"await" = Mutex.@"await",
            },
            .ptr = undefined,
        },
    };
    // this is safe because Fiber.lock will not exit
    // during Fiber.await, so the stack will not be reused.
    awaiter.awaiter.ptr = &awaiter;
    Fiber.@"suspend"(&awaiter.awaiter);
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
    {
        const guard = self.mutex.lock();
        defer guard.unlock();
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
}

const MutexAwaiter = struct {
    mutex: *Mutex,
    awaiter: Awaiter,
    queue_node: Node = undefined,
};

pub fn @"await"(ctx: *anyopaque, fiber: *Fiber) void {
    var awaiter: *MutexAwaiter = @alignCast(@ptrCast(ctx));
    var self = awaiter.mutex;
    {
        const guard = self.mutex.lock();
        defer guard.unlock();
        if (self.locked.load(.seq_cst) == false) {
            fiber.scheduleSelf();
            return;
        }
        log.info("{s} parking itself in {*} waitqueue", .{
            fiber.name,
            self,
        });
        awaiter.queue_node = .{
            .fiber = fiber,
        };
        self.queue.pushBack(&awaiter.queue_node);
    }
}

test {
    _ = @import("./mutex/tests.zig");
}
