const std = @import("std");
const builtin = @import("builtin");
const Order = std.math.Order;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const atomic = std.atomic;

const TimerQueue = @This();
const Executor = @import("../executors.zig").Executor;
const Runnable = @import("../runnable.zig");

pub const CallbackFn = *const fn (?*anyopaque) void;

// TODO: abstract away platform-dependent implementation
const kqueue = std.posix.kqueue;
const Kevent = std.posix.Kevent;
const kevent = std.posix.kevent;
const EV = std.posix.system.EV;
const EVFILT = std.posix.system.EVFILT;
const NOTE = std.posix.system.NOTE;

allocator: Allocator,
executor: Executor,
runnable: Runnable,

// TODO: abstract away platform-dependent implementation
kq_ident: usize,
event_to_submit: Kevent = undefined,
events_triggered: []Kevent,

state: atomic.Value(usize) = .init(@intFromEnum(State.idle)),
config: Config,

const State = enum(usize) {
    idle = 0,
    _,
};

const Entry = struct {
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
) !TimerQueue {
    const kq: usize = @intCast(try kqueue());
    const events_triggered = try allocator.alloc(Kevent, config.batch_count);
    errdefer allocator.free(events_triggered);
    return TimerQueue{
        .kq_ident = kq,
        .events_triggered = events_triggered,
        .allocator = allocator,
        .executor = executor,
        .runnable = .{
            .runFn = &TimerQueue.run,
        },
        .config = config,
    };
}

pub fn run(runnable: *Runnable) void {
    var self: *TimerQueue = @fieldParentPtr("runnable", runnable);
    self.pollLoop() catch |e| {
        std.debug.panic("{}", .{e});
    };
}

fn schedule(self: *TimerQueue) void {
    self.executor.submitRunnable(&self.runnable);
}

pub fn submit(
    self: *TimerQueue,
    timeout_ns: u64,
    on_complete: CallbackFn,
    on_complete_user_data: ?*anyopaque,
) !void {
    const entry = try self.config.callback_entry_allocator.create(Entry);
    entry.* = .{
        .callback = on_complete,
        .user_data = on_complete_user_data,
    };
    self.event_to_submit = .{
        .ident = self.kq_ident,
        .flags = EV.ENABLE | EV.ONESHOT | EV.ADD,
        .fflags = NOTE.NSECONDS,
        .filter = EVFILT.TIMER,
        .data = @intCast(timeout_ns),
        .udata = @intFromPtr(entry),
    };
    _ = try kevent(
        @intCast(self.kq_ident),
        &.{self.event_to_submit},
        &.{},
        null,
    );
    if (self.state.fetchAdd(1, .acq_rel) == 0) {
        self.schedule();
    }
}

pub fn pollLoop(self: *TimerQueue) !void {
    const events_triggered_num = try kevent(
        @intCast(self.kq_ident),
        &.{},
        self.events_triggered,
        null,
    );
    for (self.events_triggered[0..events_triggered_num]) |event| {
        const entry: *Entry = @ptrFromInt(event.udata);
        entry.callback(entry.user_data);
        self.config.callback_entry_allocator.destroy(entry);
    }
    if (self.state.fetchSub(events_triggered_num, .acq_rel) > events_triggered_num) {
        self.schedule();
    }
}

pub fn deinit(self: *TimerQueue) void {
    self.allocator.free(self.events_triggered);
}
