//! Wait Group for Fibers.
//! Waiting on a WaitGroup does not block the underlying thread -
//! instead, the fiber is parked until the WaitGroup counter reaches 0.
const std = @import("std");
const WaitGroup = @This();
const Atomic = std.atomic.Value;

const Spinlock = @import("../sync.zig").Spinlock;
const IntrusiveList = @import("../containers.zig").Intrusive.ForwardList;
const List = IntrusiveList.IntrusiveForwardList(Node);

const Fiber = @import("../fiber.zig");
const Awaiter = @import("./awaiter.zig");

const log = std.log.scoped(.fiber_waitgroup);

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: IntrusiveList.Node = .{},
};

counter: Atomic(isize) = .init(0),
// protects queue
mutex: Spinlock = .{},
// is protected by mutex
queue: List = .{},

pub fn add(self: *WaitGroup, count: isize) void {
    const prev_counter = self.counter.fetchAdd(count, .seq_cst);
    log.info("{*}: {}->{}", .{
        self,
        prev_counter,
        count + prev_counter,
    });
}

pub fn wait(self: *WaitGroup) void {
    log.info("{s} about to wait for {*}", .{
        Fiber.current().?.name,
        self,
    });

    if (self.counter.load(.seq_cst) == 0) {
        return;
    }
    // place awaiter on Fiber stack
    var awaiter: WaitGroupAwaiter = .{
        .awaiter = .{
            .vtable = .{
                .@"await" = WaitGroup.@"await",
            },
            .ptr = undefined,
        },
        .wait_group = self,
    };
    // this is safe because Fiber.wait will not exit
    // during Fiber.await.
    awaiter.awaiter.ptr = &awaiter;
    Fiber.@"suspend"(&awaiter.awaiter);
}

pub fn done(self: *WaitGroup) void {
    const prev_counter = self.counter.fetchSub(1, .seq_cst);
    const counter = prev_counter - 1;
    log.info("{s}: {*} {}->{}", .{
        Fiber.current().?.name,
        self,
        prev_counter,
        counter,
    });

    if (counter == 0) {
        log.info(
            "{s} set wait group counter to 0. Will resume all parked fibers.",
            .{Fiber.current().?.name},
        );
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

const WaitGroupAwaiter = struct {
    awaiter: Awaiter,
    wait_group: *WaitGroup,
    queue_node: Node = undefined,
};

pub fn @"await"(
    ctx: *anyopaque,
    fiber: *Fiber,
) void {
    var awaiter: *WaitGroupAwaiter = @ptrCast(@alignCast(ctx));
    var self: *WaitGroup = awaiter.wait_group;
    {
        const guard = self.mutex.lock();
        defer guard.unlock();
        const counter = self.counter.load(.seq_cst);
        if (counter == 0) {
            fiber.scheduleSelf();
            return;
        }
        log.info("{s} {*}: saw counter value {}", .{
            Fiber.current().?.name,
            self,
            counter,
        });
        awaiter.queue_node = .{
            .fiber = fiber,
        };
        self.queue.pushBack(&awaiter.queue_node);
    }
}

test {
    _ = @import("./wait_group/tests.zig");
}
