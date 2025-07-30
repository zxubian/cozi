const cozi = @import("../../root.zig");
const std = @import("std");
const Worker = @This();
const Awaiter = cozi.await.Awaiter;
pub const Thread = @import("./thread.zig");
const log = cozi.core.log.scoped(.worker);

vtable: VTable,
ptr: *anyopaque,
type: WorkerType,

const WorkerType = enum {
    thread,
    fiber,
};

threadlocal var current_: ?Worker = null;

pub const VTable = struct {
    @"suspend": *const fn (self: *anyopaque, awaiter: Awaiter) void,
    @"resume": *const fn (self: *anyopaque) void,
    getName: *const fn (self: *anyopaque) [:0]const u8,
    setName: *const fn (self: Worker, name: [:0]const u8) void,
};

pub inline fn @"suspend"(self: Worker, awaiter: Awaiter) void {
    self.vtable.@"suspend"(self.ptr, awaiter);
}

pub inline fn @"resume"(self: Worker) void {
    self.vtable.@"resume"(self.ptr);
}

pub inline fn getName(self: Worker) [:0]const u8 {
    return self.vtable.getName(self.ptr);
}

pub inline fn setName(self: Worker, name: [:0]const u8) void {
    return self.vtable.setName(self.ptr, name);
}

pub fn beginScope(new: Worker) Worker {
    const previous = current();
    log.debug(
        "{s} running on {s}",
        .{
            new.getName(),
            previous.getName(),
        },
    );
    current_ = new;
    return previous;
}

pub fn endScope(restore: Worker) void {
    log.debug(
        "{s} STOPPED running on {s}",
        .{
            if (current_) |c| c.getName() else "null",
            restore.getName(),
        },
    );
    current_ = restore;
}

pub fn current() Worker {
    if (current_ == null) {
        current_ = Thread.systemThreadWorker();
    }
    return current_.?;
}

test {
    _ = @import("./tests.zig");
}
