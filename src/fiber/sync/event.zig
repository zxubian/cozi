//! One-shot event for fibers.
//! Waiting on `Event` does not block the underlying thread -
//! instead, the `Fiber` is parked until the event is fired.
//! Similar to `std.Thread.ResetEvent`
const std = @import("std");

const cozi = @import("../../root.zig");
const fault = cozi.fault;
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const log = cozi.core.log.scoped(.fiber_event);

const containers = cozi.containers;
const Queue = containers.intrusive.lock_free.MpscQueue;

const Fiber = cozi.Fiber;
const GenericAwait = cozi.Await;
const Await = GenericAwait.@"await";
const Awaiter = GenericAwait.Awaiter;

const Event = @This();

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: containers.intrusive.Node = .{},
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

    // --- type-erased awaiter interface ---
    pub fn awaitSuspend(
        ctx: *anyopaque,
        handle: *anyopaque,
    ) Awaiter.AwaitSuspendResult {
        const self: *EventAwaiter = @ptrCast(@alignCast(ctx));
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        var event: *Event = self.event;
        if (event.state.load(.seq_cst) == .fired) {
            return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
        }
        self.queue_node = .{
            .fiber = fiber,
        };
        event.queue.pushBack(&self.queue_node);
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }

    pub fn awaiter(self: *EventAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{ .await_suspend = awaitSuspend },
        };
    }

    /// --- comptime awaiter interface ---
    pub fn awaitReady(self: *EventAwaiter) bool {
        return self.event.state.load(.seq_cst) == .fired;
    }

    pub fn awaitResume(_: *EventAwaiter, _: bool) void {}
};

test {
    _ = @import("./event/tests.zig");
}
