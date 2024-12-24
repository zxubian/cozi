//! One-shot event for fibers.
//! Waiting on event does not block the underlying thread -
//! instead, the fiber is parked until the event is fired.
const std = @import("std");
const Event = @This();
const Atomic = std.atomic.Value;

const Containers = @import("../containers.zig");
const Queue = Containers.Intrusive.LockFree.MpscLockFreeQueue;

const Fiber = @import("../fiber.zig");
const Await = @import("../await.zig").@"await";
const Awaiter = @import("../awaiter.zig");

const log = std.log.scoped(.fiber_event);

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: Containers.Intrusive.Node = .{},
};
const State = enum(u8) { init, fired };

state: Atomic(State) = .init(.init),
// is protected by mutex
queue: Queue(Node) = .{},

pub fn wait(self: *Event) void {
    log.info("{s} about to wait for {*}", .{ Fiber.current().?.name, self });
    // place awaiter on Fiber stack
    var event_awaiter: EventAwaiter = .{ .event = self };
    Await(&event_awaiter);
}

/// One-shot fire. Will schedule all waiting fibers.
pub fn fire(self: *Event) void {
    log.info("{s} about to fire {*}", .{
        Fiber.current().?.name,
        self,
    });
    self.state.store(.fired, .seq_cst);
    while (true) {
        if (self.queue.popFront()) |next| {
            log.info("{s} about to schedule {s}", .{
                Fiber.current().?.name,
                next.fiber.name,
            });
            next.fiber.scheduleSelf();
        } else break;
    }
}

const EventAwaiter = struct {
    event: *Event,
    queue_node: Node = undefined,

    pub fn awaiter(self: *EventAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = awaitSuspend,
                .await_resume = awaitResume,
                .await_ready = awaitReady,
            },
        };
    }

    pub fn awaitReady(ctx: *anyopaque) bool {
        const self: *EventAwaiter = @ptrCast(@alignCast(ctx));
        return self.event.state.load(.seq_cst) == .fired;
    }

    pub fn awaitResume(_: *anyopaque) void {}

    pub fn awaitSuspend(ctx: *anyopaque, handle: *anyopaque) bool {
        const self: *EventAwaiter = @ptrCast(@alignCast(ctx));
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        var event: *Event = self.event;
        if (event.state.load(.seq_cst) == .fired) {
            return true;
        }
        self.queue_node = .{
            .fiber = fiber,
        };
        event.queue.pushBack(&self.queue_node);
        return false;
    }
};

test {
    _ = @import("./event/tests.zig");
}
