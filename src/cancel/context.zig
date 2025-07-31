const std = @import("std");

const cozi = @import("../root.zig");
const List = cozi.containers.intrusive.ForwardList;
const Stack = List;
const Node = cozi.containers.intrusive.Node;

const CancelContext = @This();
const Callback = cozi.core.Runnable;

intrusive_list_node: Node = .{},
state: cozi.fault.stdlike.atomic.Value(State) = .init(.init),

callbacks_lock: cozi.sync.Spinlock = .{},
cancel_callbacks: List(Callback) = .{},
on_parent_cancelled: Callback = undefined,

const State = enum(u8) {
    init,
    cancelled,
};

threadlocal var stack: Stack(CancelContext) = .{};

pub fn beginScope(new: *CancelContext) void {
    stack.pushFront(new);
}

pub fn endScope() void {
    _ = stack.popFront();
}

pub fn current() ?*CancelContext {
    if (stack.head) |curr| {
        return curr.parentPtr(CancelContext);
    }
    return null;
}

pub const AddCallbackError = error{
    already_cancelled,
};

pub fn addCancellationListener(
    self: *CancelContext,
    callback: *Callback,
) AddCallbackError!void {
    var guard = self.callbacks_lock.guard();
    guard.lock();
    defer guard.unlock();
    if (self.state.load(.seq_cst) == .cancelled) {
        return AddCallbackError.already_cancelled;
    }
    self.cancel_callbacks.pushBack(callback);
}

pub fn removeCancellationListener(
    self: *CancelContext,
    callback: *Callback,
) void {
    var guard = self.callbacks_lock.guard();
    guard.lock();
    defer guard.unlock();
    self.cancel_callbacks.remove(callback) catch {};
}

pub fn onParentCancelled(self: *CancelContext) void {
    self.cancel();
}

pub fn cancel(self: *CancelContext) void {
    if (self.state.cmpxchgStrong(
        .init,
        .cancelled,
        .seq_cst,
        .seq_cst,
    ) == null) {
        var guard = self.callbacks_lock.guard();
        guard.lock();
        defer guard.unlock();
        while (self.cancel_callbacks.popFront()) |callback| {
            callback.run();
        }
    }
}

pub const CheckPointError = error{
    cancelled,
};

pub fn isCancelled(self: *CancelContext) bool {
    return (self.state.load(.seq_cst) == .cancelled);
}

pub fn check(self: *CancelContext) CheckPointError!void {
    if (self.isCancelled()) {
        return CheckPointError.cancelled;
    }
}

pub fn checkPoint() CheckPointError!void {
    if (current()) |curr| {
        return curr.check();
    }
}

pub fn link(
    parent: *CancelContext,
    child: *CancelContext,
) !void {
    child.on_parent_cancelled = .{
        .runFn = @ptrCast(&cancel),
        .ptr = child,
        .intrusive_list_node = .{},
    };
    try parent.addCancellationListener(&child.on_parent_cancelled);
}

pub fn unlink(
    parent: *CancelContext,
    child: *CancelContext,
) void {
    parent.removeCancellationListener(&child.on_parent_cancelled);
}
