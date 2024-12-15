//! One-shot event for fibers.
//! Waiting on event does not block the underlying thread -
//! instead, the fiber is parked until the event is fired.
const std = @import("std");
const Event = @This();
const Atomic = std.atomic.Value;

const Spinlock = @import("../sync.zig").Spinlock;
const IntrusiveList = @import("../containers.zig").Intrusive.ForwardList;
const List = IntrusiveList.IntrusiveForwardList(Node);

const Fiber = @import("../fiber.zig");
const Awaiter = @import("./awaiter.zig");

const log = std.log.scoped(.fiber_event);

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: IntrusiveList.Node = .{},
};
const State = enum(u8) { init, fired };

state: Atomic(State) = .init(.init),
// protects list
mutex: Spinlock = .{},
// is protected by mutex
queue: List = .{},

pub fn wait(self: *Event) void {
    log.info("{s} about to wait for {*}", .{ Fiber.current().?.name, self });
    if (self.state.load(.seq_cst) == .fired) {
        return;
    }
    // place awaiter on Fiber stack
    var awaiter: EventAwaiter = .{
        .awaiter = .{
            .vtable = .{
                .@"await" = Event.@"await",
            },
            .ptr = undefined,
        },
        .event = self,
    };
    // this is safe because Fiber.wait will not exit
    // during Fiber.await.
    awaiter.awaiter.ptr = &awaiter;
    Fiber.@"suspend"(&awaiter.awaiter);
}

/// One-shot fire. Will schedule all waiting fibers.
pub fn fire(self: *Event) void {
    log.info("{s} about to fire {*}", .{
        Fiber.current().?.name,
        self,
    });
    self.state.store(.fired, .seq_cst);
    {
        const guard = self.mutex.lock();
        defer guard.unlock();
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
}

const EventAwaiter = struct {
    awaiter: Awaiter,
    event: *Event,
    queue_node: Node = undefined,
};

pub fn @"await"(ctx: *anyopaque, fiber: *Fiber) void {
    var awaiter: *EventAwaiter = @ptrCast(@alignCast(ctx));
    var self: *Event = awaiter.event;
    {
        const guard = self.mutex.lock();
        defer guard.unlock();
        if (self.state.load(.seq_cst) == .fired) {
            fiber.scheduleSelf();
            return;
        }
        awaiter.queue_node = .{
            .fiber = fiber,
        };
        self.queue.pushBack(&awaiter.queue_node);
    }
}

test {
    _ = @import("./event/tests.zig");
}
