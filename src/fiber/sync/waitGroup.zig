//! Wait Group for Fibers.
//! Waiting on a WaitGroup does not block the underlying thread -
//! instead, the fiber is parked until the WaitGroup counter reaches 0.
const std = @import("std");
const WaitGroup = @This();

const fault = @import("../../fault/root.zig");
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;

const containers = @import("../../containers/root.zig");
const Queue = containers.intrusive.lock_free.MpscQueue;

const Fiber = @import("../../fiber/root.zig");
const GenericAwait = @import("../../await/root.zig");
const Await = GenericAwait.@"await";
const Awaiter = GenericAwait.Awaiter;

const log = std.log.scoped(.fiber_waitgroup);

const Node = struct {
    fiber: *Fiber,
    intrusive_list_node: containers.intrusive.Node = .{},
};

const State = packed struct(u64) {
    counter: u32 = 0,
    num_waiters: u32 = 0,
};

state: Atomic(u64) = .init(0),
queue: Queue(Node) = .{},

pub fn init(initial_value: u32) WaitGroup {
    return WaitGroup{
        .state = @bitCast(State{ .counter = initial_value }),
    };
}

pub fn add(self: *WaitGroup, count: u32) void {
    const prev_counter = self.state.fetchAdd(count, .seq_cst);
    log.debug("{*}: {}->{}", .{
        self,
        @as(State, @bitCast(prev_counter)),
        @as(State, @bitCast(prev_counter + count)),
    });
}

pub fn wait(self: *WaitGroup) void {
    log.debug("{s} about to wait for {*}", .{
        Fiber.current().?.name,
        self,
    });
    // add waiter
    const prev_state_raw = self.state.fetchAdd(1 << 32, .seq_cst);
    const state_raw = prev_state_raw + (1 << 32);
    const prev_state: State = @bitCast(prev_state_raw);
    const state: State = @bitCast(state_raw);
    log.debug("{*}: {}->{}", .{
        self,
        prev_state,
        state,
    });
    // fast path - no suspend necessary
    if (state.counter == 0) {
        _ = self.state.fetchSub(1 << 32, .seq_cst);
        return;
    }
    // place awaiter on Fiber stack
    var wait_group_awaiter: WaitGroupAwaiter = .{ .wait_group = self };
    Await(&wait_group_awaiter);
}

pub fn done(self: *WaitGroup) void {
    const prev_state_raw = self.state.fetchSub(1, .seq_cst);
    if (prev_state_raw == 0) {
        std.debug.panic("Cannot call WaitGroup.done() before WaitGroup.add()", .{});
    }
    const state_raw = prev_state_raw - 1;
    const prev_state: State = @bitCast(prev_state_raw);
    var state: State = @bitCast(state_raw);
    log.debug("{s}: {*} {}->{}", .{
        Fiber.current().?.name,
        self,
        @as(State, @bitCast(prev_state)),
        @as(State, @bitCast(state)),
    });
    if (state.counter > 0) {
        return;
    }
    log.debug(
        "{s} set wait group counter to 0. Will resume all parked fibers.",
        .{Fiber.current().?.name},
    );
    while (state.num_waiters > 0) : ({
        state = @bitCast(self.state.load(.seq_cst));
    }) {
        while (self.queue.popFront()) |next| {
            log.debug("{s} about to schedule {s}", .{
                Fiber.current().?.name,
                next.fiber.name,
            });
            next.fiber.scheduleSelf();
            state = @bitCast(self.state.fetchSub(1 << 32, .seq_cst) - 1 << 32);
        }
        std.atomic.spinLoopHint();
    }
}

const WaitGroupAwaiter = struct {
    wait_group: *WaitGroup,
    queue_node: Node = undefined,

    // --- type-erased awaiter interface ---
    pub fn awaitSuspend(
        ctx: *anyopaque,
        handle: *anyopaque,
    ) Awaiter.AwaitSuspendResult {
        var self: *WaitGroupAwaiter = @ptrCast(@alignCast(ctx));
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        const state: State = @bitCast(self.wait_group.state.load(.seq_cst));
        if (state.num_waiters == 0) {
            _ = self.wait_group.state.fetchSub(1 << 32, .seq_cst);
            return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
        }
        self.queue_node = .{
            .fiber = fiber,
        };
        self.wait_group.queue.pushBack(&self.queue_node);
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }

    pub fn awaiter(self: *WaitGroupAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{ .await_suspend = awaitSuspend },
        };
    }

    /// --- comptime awaiter interface ---
    pub fn awaitReady(self: *WaitGroupAwaiter) bool {
        const state: State = @bitCast(self.wait_group.state.load(.seq_cst));
        if (state.num_waiters == 0) {
            _ = self.wait_group.state.fetchSub(1 << 32, .seq_cst);
            return true;
        }
        return false;
    }

    pub fn awaitResume(_: *WaitGroupAwaiter, _: bool) void {}
};

test {
    _ = @import("./waitGroup/tests.zig");
}
