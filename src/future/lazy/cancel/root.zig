const std = @import("std");
const cozi = @import("../../../root.zig");
const Runnable = cozi.core.Runnable;
const testing = std.testing;
const executors = cozi.executors;
const ManualExecutor = executors.Manual;

const cancel = @This();

pub const withCancellation = @import("./withCancellation.zig");

pub const CancellationError = error{
    canceled,
};

pub fn initNoAlloc(state: *State) std.meta.Tuple(&[_]type{ Source, Token }) {
    return .{
        .{
            .state = state,
        },
        .{
            .state = state,
        },
    };
}

pub const Callback = struct {
    intrusive_list_node: cozi.containers.intrusive.Node = .{},
    runnable: Runnable,
    executor: cozi.executors.Executor,

    pub inline fn run(self: *@This()) void {
        self.executor.submitRunnable(&self.runnable);
    }
};

pub const Source = struct {
    state: *State,

    pub fn cancel(self: @This()) void {
        self.state.cancel();
    }

    pub fn getCancelAsCallback(self: *@This()) Callback {
        return Callback{
            .runnable = .{
                .runFn = Source.cancel,
                .ptr = self,
            },
            .executor = executors.@"inline",
        };
    }
};

pub const State = struct {
    cancelled: cozi.fault.stdlike.atomic.Value(bool) = .init(false),
    spinlock: cozi.sync.Spinlock = .{},
    subscribers: cozi.containers.intrusive.ForwardList(Callback) = .{},

    pub fn isCancelled(self: *@This()) bool {
        return self.cancelled.load(.seq_cst);
    }

    pub fn subscribe(self: *@This(), callback: *Callback) void {
        var guard = self.spinlock.guard();
        guard.lock();
        defer guard.unlock();
        if (self.isCancelled()) {
            callback.run();
        } else {
            self.subscribers.pushBack(callback);
        }
    }

    pub fn cancel(self: *@This()) void {
        var guard = self.spinlock.guard();
        guard.lock();
        defer guard.unlock();
        if (self.cancelled.cmpxchgStrong(false, true, .seq_cst, .seq_cst)) |_| {
            @branchHint(.unlikely);
            std.debug.panic("Cancelling twice", .{});
        }
        while (self.subscribers.popFront()) |next| {
            next.run();
        }
    }
};

pub const Token = struct {
    state: *State,

    pub inline fn isCancelled(self: @This()) bool {
        return self.state.isCancelled();
    }

    pub fn subscribe(self: @This(), callback: *Callback) void {
        self.state.subscribe(callback);
    }
};
