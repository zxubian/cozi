const std = @import("std");
const builtin = @import("builtin");
const Order = std.math.Order;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const atomic = std.atomic;

const Dispatch = @This();

const Core = @import("../core/root.zig");
const Runnable = Core.Runnable;
const Closure = Core.Closure;
const executors = @import("../executors/root.zig");
const Executor = executors.Executor;

pub const OnEntryCompleted = *const fn (
    dispatch: *Dispatch,
    ctx: *anyopaque,
) void;

allocator: Allocator,
executor: Executor,
runnable: Runnable = .{
    .runFn = run,
    .ptr = undefined,
},

state: atomic.Value(usize) = .init(@intFromEnum(State.idle)),
config: Config,

impl: Impl,

const Impl = switch (builtin.os.tag) {
    .macos => @import("./dispatch/kqueImpl.zig"),
    else => @compileError("todo"),
};

const State = enum(usize) {
    idle = 0,
    _,
};

pub const Config = struct {
    batch_count: usize = 256,
    callback_entry_allocator: Allocator,
};

pub fn init(
    config: Config,
    executor: Executor,
    allocator: Allocator,
) !Dispatch {
    const impl = try Impl.init(config, allocator);
    return Dispatch{
        .allocator = allocator,
        .executor = executor,
        .impl = impl,
        .config = config,
    };
}

pub fn run(ctx: *anyopaque) void {
    var self: *Dispatch = @alignCast(@ptrCast(ctx));
    self.pollBatch() catch |e| {
        std.debug.panic("Error in IO dispatch: {}", .{e});
    };
}

fn schedule(self: *Dispatch) void {
    self.runnable.ptr = self;
    self.executor.submitRunnable(&self.runnable);
}

pub fn timer(
    self: *Dispatch,
    timeout_ns: u64,
    on_complete: anytype,
    on_complete_user_data: std.meta.ArgsTuple(@TypeOf(on_complete)),
) !void {
    const closure = try Closure(on_complete).Managed.init(
        on_complete_user_data,
        self.config.callback_entry_allocator,
    );
    errdefer self.config.callback_entry_allocator.destroy(closure);
    try self.impl.timer(timeout_ns, closure.runnable());
    if (self.state.fetchAdd(1, .acq_rel) ==
        @intFromEnum(State.idle))
    {
        self.schedule();
    }
}

pub fn submitOnExecutor() void {}

pub fn pollBatch(self: *Dispatch) !void {
    const events_triggered_num = try self.impl.pollBatch(onEntryCompleted);
    if (self.state.fetchSub(
        events_triggered_num,
        .acq_rel,
    ) - events_triggered_num > 0) {
        // if any events remain
        self.schedule();
    }
}

fn onEntryCompleted(self: *Dispatch, ctx: *anyopaque) void {
    const callback_runnable: *Runnable = @alignCast(@ptrCast(ctx));
    self.executor.submitRunnable(callback_runnable);
}

pub fn deinit(self: *Dispatch) void {
    self.impl.deinit(self.allocator);
}

test {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            _ = @import("./dispatch/tests.zig");
        },
        else => {},
    }
}
