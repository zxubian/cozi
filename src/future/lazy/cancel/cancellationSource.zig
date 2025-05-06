const std = @import("std");
const cozi = @import("../../../root.zig");
const Runnable = cozi.core.Runnable;
const testing = std.testing;
const executors = cozi.executors;
const ManualExecutor = executors.Manual;

const CancelSource = struct {
    state: *CancelState,

    pub fn createToken(self: @This()) CancelToken {
        return .{
            .state = self.state,
        };
    }

    pub inline fn cancel(self: @This()) void {
        self.state.cancel();
    }
};

const CancelState = struct {
    cancelled: cozi.fault.stdlike.atomic.Value(bool) = .init(false),
    spinlock: cozi.sync.Spinlock = .{},
    subscribers: cozi.containers.intrusive.ForwardList(Callback) = .{},

    pub const Callback = struct {
        intrusive_list_node: cozi.containers.intrusive.Node = .{},
        runnable: Runnable,
        executor: cozi.executors.Executor,

        pub inline fn run(self: *@This()) void {
            self.executor.submitRunnable(&self.runnable);
        }
    };

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

const CancelToken = struct {
    state: *CancelState,
    pub inline fn isCancelled(self: @This()) bool {
        return self.state.isCancelled();
    }
    pub fn subscribe(self: *@This(), callback: *CancelState.Callback) void {
        self.state.subscribe(callback);
    }
};

test "cancel - basic" {
    var state: CancelState = .{};
    var source: CancelSource = .{ .state = &state };
    const token = source.createToken();
    try testing.expect(!token.isCancelled());
    source.cancel();
    try testing.expect(token.isCancelled());
}

test "cancel - subscribe" {
    var manual_executor: ManualExecutor = .{};
    const executor = manual_executor.executor();

    var state: CancelState = .{};
    var source: CancelSource = .{ .state = &state };
    var token = source.createToken();
    try testing.expect(!token.isCancelled());
    const Ctx = struct {
        done: bool,
        pub fn onCancel(self: *@This()) void {
            self.done = true;
        }
    };
    var ctx: Ctx = .{ .done = false };
    var callback: CancelState.Callback = .{
        .runnable = .{
            .runFn = @ptrCast(&Ctx.onCancel),
            .ptr = &ctx,
        },
        .executor = executor,
    };
    token.subscribe(&callback);
    source.cancel();
    try testing.expect(token.isCancelled());
    _ = manual_executor.drain();
    try testing.expect(ctx.done);
}
