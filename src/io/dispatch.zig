const std = @import("std");
const builtin = @import("builtin");
const Order = std.math.Order;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const atomic = std.atomic;

const Dispatch = @This();
const Executor = @import("../executors.zig").Executor;
const Runnable = @import("../runnable.zig");

pub const CallbackFn = *const fn (?*anyopaque) void;

allocator: Allocator,
executor: Executor,
runnable: Runnable,

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

pub const Entry = struct {
    callback: CallbackFn,
    user_data: ?*anyopaque,
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
        .runnable = .{
            .runFn = &Dispatch.run,
        },
        .config = config,
    };
}

pub fn run(runnable: *Runnable) void {
    var self: *Dispatch = @fieldParentPtr("runnable", runnable);
    self.pollBatch() catch |e| {
        std.debug.panic("{}", .{e});
    };
}

fn schedule(self: *Dispatch) void {
    self.executor.submitRunnable(&self.runnable);
}

pub fn timer(
    self: *Dispatch,
    timeout_ns: u64,
    on_complete: CallbackFn,
    on_complete_user_data: ?*anyopaque,
) !void {
    const entry = try self.config.callback_entry_allocator.create(Entry);
    entry.* = .{
        .callback = on_complete,
        .user_data = on_complete_user_data,
    };
    errdefer self.config.callback_entry_allocator.destroy(entry);
    try self.impl.timer(timeout_ns, entry);
    if (self.state.fetchAdd(1, .acq_rel) == 0) {
        self.schedule();
    }
}

pub const OnEntryCompleted = *const fn (self: *Dispatch, entry: *Entry) void;

pub fn pollBatch(self: *Dispatch) !void {
    const events_triggered_num = try self.impl.pollBatch(onEntryCompleted);
    if (self.state.fetchSub(events_triggered_num, .acq_rel) > events_triggered_num) {
        self.schedule();
    }
}

fn onEntryCompleted(self: *Dispatch, entry: *Entry) void {
    entry.callback(entry.user_data);
    self.config.callback_entry_allocator.destroy(entry);
}

pub fn deinit(self: *Dispatch) void {
    self.impl.deinit(self.allocator);
}

test {
    _ = @import("./dispatch/tests.zig");
}
