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
    executor: cozi.executors.Executor = cozi.executors.@"inline",

    pub inline fn run(self: *@This()) void {
        self.executor.submitRunnable(&self.runnable);
    }
};

pub const Source = struct {
    state: *State,

    pub fn cancel(self: @This()) void {
        self.state.cancel();
    }

    pub fn getCancelAsCallback(self: @This()) Callback {
        return Callback{
            .runnable = .{
                .runFn = @ptrCast(&State.cancel),
                .ptr = self.state,
            },
            .executor = executors.@"inline",
        };
    }
};

pub const State = struct {
    cancelled: cozi.fault.stdlike.atomic.Value(bool) = .init(false),
    spinlock: cozi.sync.Spinlock = .{},
    subscribers: cozi.containers.intrusive.ForwardList(Callback) = .{},

    pub fn isCanceled(self: *@This()) bool {
        return self.cancelled.load(.seq_cst);
    }

    pub fn subscribe(self: *@This(), callback: *Callback) void {
        var guard = self.spinlock.guard();
        guard.lock();
        defer guard.unlock();
        if (self.isCanceled()) {
            callback.run();
        } else {
            self.subscribers.pushBack(callback);
        }
    }

    pub fn cancel(self: *@This()) void {
        var guard = self.spinlock.guard();
        guard.lock();
        defer guard.unlock();
        if (self.cancelled.cmpxchgStrong(
            false,
            true,
            .seq_cst,
            .seq_cst,
        )) |_| {
            @branchHint(.unlikely);
            std.debug.panic("Canceling twice", .{});
        }
        while (self.subscribers.popFront()) |next| {
            next.run();
        }
    }
};

pub const Token = struct {
    state: *State,

    pub inline fn isCanceled(self: @This()) bool {
        return self.state.isCanceled();
    }

    pub fn subscribe(
        self: @This(),
        callback: *Callback,
    ) void {
        self.state.subscribe(callback);
    }
};

pub const LinkedSource = struct {
    source: Source,
    callback: Callback = undefined,

    pub fn fromState(state: *State) @This() {
        const source: Source = .{
            .state = state,
        };
        return fromSource(source);
    }

    pub fn fromSource(source: Source) @This() {
        return .{
            .source = source,
            .callback = source.getCancelAsCallback(),
        };
    }

    pub fn linkTo(
        self: *@This(),
        token: Token,
    ) void {
        self.callback = self.source.getCancelAsCallback();
        token.subscribe(&self.callback);
    }
};

pub const Context = struct {
    state: *State,
    on_cancel: Callback,

    pub fn init(
        self: *@This(),
        ctx_parent_ptr: anytype,
        state: *State,
    ) void {
        self.state = state;
        self.on_cancel = Callback{
            .runnable = .{
                .runFn = @ptrCast(
                    &@TypeOf(ctx_parent_ptr.*).onCancel,
                ),
                .ptr = ctx_parent_ptr,
            },
        };
        self.state.subscribe(&self.on_cancel);
    }

    pub inline fn subscribe(self: @This(), callback: *Callback) void {
        self.state.subscribe(callback);
    }

    pub inline fn isCanceled(self: @This()) bool {
        return self.state.isCanceled();
    }

    pub inline fn cancel(self: @This()) void {
        self.state.cancel();
    }
};

pub const LinkedContext = struct {
    ctx: Context,
    on_parent_cancel_callback: Callback = undefined,
    const Impl = @This();

    pub fn init(
        self: *@This(),
        ctx_parent_ptr: anytype,
        state: *State,
    ) void {
        self.ctx.init(ctx_parent_ptr, state);
    }

    pub fn linkTo(
        self: *Impl,
        parent: Context,
    ) void {
        self.on_parent_cancel_callback = .{
            .runnable = .{
                .runFn = @ptrCast(&onParentCancel),
                .ptr = self,
            },
        };
        parent.subscribe(
            &self.on_parent_cancel_callback,
        );
    }

    fn onParentCancel(self: *Impl) void {
        self.ctx.cancel();
    }

    pub inline fn isCanceled(self: Impl) bool {
        return self.ctx.isCanceled();
    }
};

pub fn linkToNext(
    self_ptr: anytype,
    next_ctx: anytype,
) void {
    const next_cancel_context =
        if (@TypeOf(next_ctx) == LinkedContext)
            next_ctx.ctx
        else
            next_ctx;
    self_ptr.cancel_ctx.linkTo(next_cancel_context);
}
