const std = @import("std");

const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;
const core = cozi.core;
const SpinLock = cozi.sync.Spinlock;
const Runnable = core.Runnable;
const Await = Fiber.@"await".@"await";
const Awaiter = Fiber.@"await".Awaiter;

const Impl = @This();
const Queue = cozi.containers.intrusive.ForwardList;

queue: Queue(*Runnable) = .{},
lock: SpinLock = .{},
closed: bool = false,
idle_fibers: Queue(IdleFibersQueueEntry) = .{},

const IdleFibersQueueEntry = struct {
    intrusive_list_node: cozi.containers.intrusive.Node = .{},
    fiber: *Fiber,
};

pub fn pushBack(
    self: *@This(),
    task: *Runnable,
) void {
    var guard = self.lock.guard();
    guard.lock();
    defer guard.unlock();
    if (self.closed) {
        std.debug.panic(
            "pushBack on closed queue",
            .{},
        );
    }
    if (Fiber.current()) |_| {
        var awaiter: PushBackAwaiter = .{
            .task = task,
            .queue = self,
            .guard = &guard,
        };
        Await(&awaiter);
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
    var awaiter: PopFrontAwaiter = .{
        .task_queue = self,
        .guard = &guard,
    };
    return Await(&awaiter);
}

const TryCloseError = error{already_closed};

pub fn tryClose(self: *@This()) TryCloseError!void {
    var guard = self.lock.guard();
    guard.lock();
    defer guard.unlock();
    if (self.closed) {
        return TryCloseError.already_closed;
    }
    if (Fiber.current()) |_| {
        var awaiter: CloseAwaiter = .{
            .task_queue = self,
            .guard = &guard,
        };
        Await(&awaiter);
    } else {
        self.closed = true;
        while (self.idle_fibers.popFront()) |next| {
            next.fiber.scheduleSelf();
        }
    }
}

const PushBackAwaiter = struct {
    task: *Runnable,
    task_queue: *Impl,
    guard: *SpinLock.Guard,
    fiber: *Fiber,

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
        fiber: *Fiber,
    ) Awaiter.AwaitSuspendResult {
        self.fiber = fiber;
        self.task_queue.pushBack(self.task);
        defer self.guard.unlock();
        if (self.task_queue.idle_fibers.popFront()) |waiting_fiber| {
            return Awaiter.AwaitSuspendResult{
                .symmetric_transfer_next = waiting_fiber,
            };
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
        fiber: *Fiber,
    ) Awaiter.AwaitSuspendResult {
        defer self.guard.unlock();
        if (self.task_queue.closed) {
            return .never_suspend;
        }
        if (self.task_queue.queue.isEmpty()) {
            self.entry = .{
                .fiber = fiber,
            };
            self.task_queue.idle_fibers.pushBack(&self.entry);
            return .always_suspend;
        }
        return .never_suspend;
    }

    pub fn awaitReady(self: *@This()) bool {
        return self.task_queue.closed or
            !self.task_queue.queue.isEmpty();
    }

    pub fn awaitResume(self: *@This(), suspended: bool) ?*Runnable {
        if (suspended) {
            self.guard.lock();
        }
        if (self.task_queue.closed) {
            return null;
        }
        return self.task_queue.popFront().?;
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
        _: *Fiber,
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
