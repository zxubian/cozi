//! Wait Group for Fibers.
//! Waiting on a WaitGroup does not block the underlying thread -
//! instead, the fiber is parked until the WaitGroup counter reaches 0.
const std = @import("std");
const WaitGroup = @This();
const Atomic = std.atomic.Value;

const Containers = @import("../../containers.zig");
const Queue = Containers.Intrusive.LockFree.MpscLockFreeQueue;

const Fiber = @import("../..//fiber.zig");
const Await = @import("../../await.zig").@"await";
const Awaiter = @import("../../awaiter.zig");

const log = std.log.scoped(.fiber_waitgroup);

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: Containers.Intrusive.Node = .{},
};

counter: Atomic(isize) = .init(0),
queue: Queue(Node) = .{},

pub fn add(self: *WaitGroup, count: isize) void {
    const prev_counter = self.counter.fetchAdd(count, .seq_cst);
    log.debug("{*}: {}->{}", .{
        self,
        prev_counter,
        count + prev_counter,
    });
}

pub fn wait(self: *WaitGroup) void {
    log.debug("{s} about to wait for {*}", .{
        Fiber.current().?.name,
        self,
    });
    // place awaiter on Fiber stack
    var wait_group_awaiter: WaitGroupAwaiter = .{ .wait_group = self };
    Await(&wait_group_awaiter);
}

pub fn done(self: *WaitGroup) void {
    const prev_counter = self.counter.fetchSub(1, .seq_cst);
    const counter = prev_counter - 1;
    log.debug("{s}: {*} {}->{}", .{
        Fiber.current().?.name,
        self,
        prev_counter,
        counter,
    });

    if (counter == 0) {
        log.debug(
            "{s} set wait group counter to 0. Will resume all parked fibers.",
            .{Fiber.current().?.name},
        );
        while (true) {
            if (self.queue.popFront()) |next| {
                log.debug("{s} about to schedule {s}", .{
                    Fiber.current().?.name,
                    next.fiber.name,
                });
                next.fiber.scheduleSelf();
            } else break;
        }
    }
}

const WaitGroupAwaiter = struct {
    wait_group: *WaitGroup,
    queue_node: Node = undefined,

    pub fn awaitReady(ctx: *anyopaque) bool {
        const self: *WaitGroupAwaiter = @ptrCast(@alignCast(ctx));
        return self.wait_group.counter.load(.seq_cst) == 0;
    }

    pub fn awaitSuspend(
        ctx: *anyopaque,
        handle: *anyopaque,
    ) bool {
        var self: *WaitGroupAwaiter = @ptrCast(@alignCast(ctx));
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        if (self.wait_group.counter.load(.seq_cst) == 0) {
            return true;
        }
        self.queue_node = .{
            .fiber = fiber,
        };
        self.wait_group.queue.pushBack(&self.queue_node);
        return false;
    }

    pub fn awaitResume(_: *anyopaque) void {}

    pub fn awaiter(self: *WaitGroupAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = awaitSuspend,
                .await_resume = awaitResume,
                .await_ready = awaitReady,
            },
        };
    }
};

test {
    _ = @import("./wait_group/tests.zig");
}
