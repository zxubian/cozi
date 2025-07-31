const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;
const core = cozi.core;
const SpinLock = cozi.sync.Spinlock;
const Runnable = core.Runnable;
const await = cozi.await.await;
const Awaiter = cozi.await.Awaiter;
const Worker = cozi.await.Worker;
const log = core.log.scoped(.fiber_pool_queue);

const Impl = @This();
const Queue = cozi.containers.intrusive.ForwardList;

queue: Queue(Runnable) = .{},
lock: SpinLock = .{},
closed_: bool = false,
idle_fibers: Queue(IdleFibersQueueEntry) = .{},

const IdleFibersQueueEntry = struct {
    intrusive_list_node: cozi.containers.intrusive.Node = .{},
    fiber: *Fiber,
};

const PushBackError = error{
    closed,
};

pub fn closed(self: *@This()) bool {
    var guard = self.lock.guard();
    guard.lock();
    defer guard.unlock();
    return self.closed_;
}

pub fn pushBack(
    self: *@This(),
    task: *Runnable,
) !void {
    var guard = self.lock.guard();
    guard.lock();
    defer guard.unlock();
    if (self.closed_) {
        return PushBackError.closed;
    }
    if (Fiber.current()) |_| {
        var awaiter: PushBackAwaiter = .{
            .task = task,
            .task_queue = self,
            .guard = &guard,
        };
        await(&awaiter);
    } else {
        self.queue.pushBack(task);
        if (self.idle_fibers.popFront()) |next| {
            next.fiber.scheduleSelf();
        }
    }
}

pub fn popFront(
    self: *@This(),
) ?*Runnable {
    var guard = self.lock.guard();
    guard.lock();
    defer guard.unlock();
    while (true) {
        var awaiter: PopFrontAwaiter = .{
            .task_queue = self,
            .guard = &guard,
        };
        const result = await(&awaiter);
        if (result == null) {
            if (!self.closed_) {
                continue;
            }
        }
        return result;
    }
}

const TryCloseError = error{
    already_closed,
};

pub fn tryClose(self: *@This()) TryCloseError!void {
    var guard = self.lock.guard();
    guard.lock();
    defer guard.unlock();
    if (self.closed_) {
        return TryCloseError.already_closed;
    }
    if (Fiber.current()) |_| {
        var awaiter: CloseAwaiter = .{
            .task_queue = self,
            .guard = &guard,
        };
        await(&awaiter);
    } else {
        self.closed_ = true;
        while (self.idle_fibers.popFront()) |next| {
            log.debug(
                "about to awake {s} because queue was closed",
                .{
                    next.fiber.name,
                },
            );
            next.fiber.scheduleSelf();
        }
    }
}

const PushBackAwaiter = struct {
    task: *Runnable,
    task_queue: *Impl,
    guard: *SpinLock.Guard,

    pub fn awaiter(self: *@This()) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = @ptrCast(&awaitSuspend),
            },
        };
    }

    pub fn awaitSuspend(
        self: *@This(),
        worker: Worker,
    ) Awaiter.AwaitSuspendResult {
        std.debug.assert(worker.type == .fiber);
        self.task_queue.queue.pushBack(self.task);
        defer self.guard.unlock();
        if (self.task_queue.idle_fibers.popFront()) |waiting_fiber| {
            waiting_fiber.fiber.scheduleSelf();
        }
        return .never_suspend;
    }

    pub fn awaitReady(_: *@This()) bool {
        return false;
    }

    pub fn awaitResume(self: *@This(), suspended: bool) void {
        if (suspended) {
            self.guard.lock();
        }
    }
};

const PopFrontAwaiter = struct {
    task_queue: *Impl,
    guard: *SpinLock.Guard,
    entry: IdleFibersQueueEntry = undefined,

    pub fn awaiter(self: *@This()) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = @ptrCast(&awaitSuspend),
            },
        };
    }

    pub fn awaitSuspend(
        self: *@This(),
        handle: Worker,
    ) Awaiter.AwaitSuspendResult {
        defer self.guard.unlock();
        if (self.task_queue.closed_) {
            return .never_suspend;
        }
        if (!self.task_queue.queue.isEmpty()) {
            return .never_suspend;
        }
        std.debug.assert(handle.type == .fiber);
        self.entry = .{
            .fiber = @alignCast(@ptrCast(handle.ptr)),
        };
        self.task_queue.idle_fibers.pushBack(&self.entry);
        return .always_suspend;
    }

    pub fn awaitReady(self: *@This()) bool {
        return self.task_queue.closed_ or
            !self.task_queue.queue.isEmpty();
    }

    pub fn awaitResume(self: *@This(), suspended: bool) ?*Runnable {
        if (suspended) {
            self.guard.lock();
        }
        return self.task_queue.queue.popFront();
    }
};

const CloseAwaiter = struct {
    task_queue: *Impl,
    guard: *SpinLock.Guard,

    pub fn awaiter(self: *@This()) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = @ptrCast(&awaitSuspend),
            },
        };
    }

    pub fn awaitReady(self: *@This()) bool {
        return self.task_queue.idle_fibers.isEmpty();
    }

    pub fn awaitSuspend(
        self: *@This(),
        _: Worker,
    ) Awaiter.AwaitSuspendResult {
        defer self.guard.unlock();
        while (self.task_queue.idle_fibers.popFront()) |next| {
            next.fiber.scheduleSelf();
        }
        return .never_suspend;
    }
    pub fn awaitResume(self: *@This(), suspended: bool) void {
        if (suspended) {
            self.guard.lock();
        }
    }
};
