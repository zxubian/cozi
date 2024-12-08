const std = @import("std");
const builtin = @import("builtin");
const Order = std.math.Order;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const atomic = std.atomic;

const Executor = @import("../../executor.zig");
const Runnable = @import("../../runnable.zig");

const Dispatch = @import("../dispatch.zig");

// TODO: abstract away platform-dependent implementation
const kqueue = std.posix.kqueue;
const Kevent = std.posix.Kevent;
const kevent = std.posix.kevent;
const EV = std.posix.system.EV;
const EVFILT = std.posix.system.EVFILT;
const NOTE = std.posix.system.NOTE;

const KqueueImpl = @This();

// TODO: abstract away platform-dependent implementation
kq_ident: usize,
event_to_submit: Kevent = undefined,
events_triggered: []Kevent,

pub fn init(
    config: Dispatch.Config,
    allocator: Allocator,
) !KqueueImpl {
    const kq: usize = @intCast(try kqueue());
    const events_triggered = try allocator.alloc(Kevent, config.batch_count);
    return KqueueImpl{
        .kq_ident = kq,
        .events_triggered = events_triggered,
    };
}

pub fn timer(
    self: *KqueueImpl,
    timeout_ns: u64,
    on_complete_entry: *Dispatch.Entry,
) !void {
    self.event_to_submit = .{
        .ident = self.kq_ident,
        .flags = EV.ENABLE | EV.ONESHOT | EV.ADD,
        .fflags = NOTE.NSECONDS,
        .filter = EVFILT.TIMER,
        .data = @intCast(timeout_ns),
        .udata = @intFromPtr(on_complete_entry),
    };
    _ = try kevent(
        @intCast(self.kq_ident),
        &.{self.event_to_submit},
        &.{},
        null,
    );
}

pub fn pollBatch(
    self: *KqueueImpl,
    on_entry_completed: Dispatch.OnEntryCompleted,
) !u64 {
    const events_triggered_num = try kevent(
        @intCast(self.kq_ident),
        &.{},
        self.events_triggered,
        null,
    );
    const parent: *Dispatch = @fieldParentPtr("impl", self);
    for (self.events_triggered[0..events_triggered_num]) |event| {
        const entry: *Dispatch.Entry = @ptrFromInt(event.udata);
        on_entry_completed(parent, entry);
    }
    return events_triggered_num;
}

pub fn deinit(self: *KqueueImpl, gpa: Allocator) void {
    gpa.free(self.events_triggered);
}
