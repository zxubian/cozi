const std = @import("std");
const cozi = @import("../../root.zig");
const Awaiter = cozi.await.Awaiter;
const Worker = cozi.await.Worker;
const log = cozi.core.log.scoped(.worker);
const SystemThreadWorker = @This();

threadlocal var this_: SystemThreadWorker = .{};

pub const State = enum(u32) {
    running,
    suspended,
};
name_buf: [std.Thread.max_name_len:0]u8 = [_:0]u8{0} ** std.Thread.max_name_len,
state: cozi.fault.stdlike.atomic.Value(u32) = .init(@intFromEnum(State.running)),
handle: ?*std.Thread = null,

pub fn init(handle: *std.Thread, name: [std.Thread.max_name_len:0]u8) !Worker {
    this_.handle = handle;
    try setName(&this_, &name);
    return worker(&this_);
}

pub inline fn worker(self: *SystemThreadWorker) Worker {
    return .{
        .ptr = self,
        .type = .thread,
        .vtable = .{
            .@"suspend" = @ptrCast(&@"suspend"),
            .@"resume" = @ptrCast(&@"resume"),
            .getName = @ptrCast(&getName),
            .setName = @ptrCast(&setName),
        },
    };
}

fn @"suspend"(self: *SystemThreadWorker, awaiter: Awaiter) void {
    if (self != &this_) {
        @branchHint(.unlikely);
        std.debug.panic(
            "Attempting to call {} for thread {*} from another thread",
            .{ @src(), self },
        );
    }
    switch (awaiter.awaitSuspend(worker(self))) {
        .never_suspend => return,
        .always_suspend => {
            log.debug("[{s}] suspend begin\n", .{getName(self)});
            if (self.state.cmpxchgStrong(
                @intFromEnum(State.running),
                @intFromEnum(State.suspended),
                .seq_cst,
                .seq_cst,
            )) |actual| {
                @branchHint(.unlikely);
                std.debug.panic(
                    "[{s}] invalid state transition. Actual: {}->{}",
                    .{
                        getName(self),
                        @as(State, @enumFromInt(actual)),
                        State.suspended,
                    },
                );
            } else {
                std.Thread.Futex.wait(&self.state, 1);
            }
        },
        .symmetric_transfer_next => {
            std.debug.panic("System threads do not support symmetric transfer", .{});
        },
    }
}

fn @"resume"(other: *SystemThreadWorker) void {
    if (other == &this_) {
        @branchHint(.unlikely);
        std.debug.panic(
            "Cannot call {} from within the same thread {*}: it is already running",
            .{ @src(), other },
        );
    }
    log.debug("[{s}] resuming", .{getName(other)});
    if (other.state.cmpxchgStrong(
        @intFromEnum(State.suspended),
        @intFromEnum(State.running),
        .seq_cst,
        .seq_cst,
    )) |actual| {
        @branchHint(.unlikely);
        std.debug.panic(
            "[{s}] invalid state transition. Actual: {}->{}",
            .{
                getName(other),
                @as(State, @enumFromInt(actual)),
                State.running,
            },
        );
    }
}

pub fn getName(self: *SystemThreadWorker) [:0]const u8 {
    return getNameWithBuffer(self, &self.name_buf) catch unreachable;
}

pub fn getNameWithBuffer(
    self: *SystemThreadWorker,
    buf: *[std.Thread.max_name_len:0]u8,
) std.fmt.BufPrintError![:0]const u8 {
    if (self.handle) |thread| {
        const maybe_name = thread.getName(buf) catch {
            const handle = thread.getHandle();
            return try std.fmt.bufPrintZ(buf, "{}", .{handle});
        };
        if (maybe_name) |name| {
            buf[name.len] = 0;
            return @ptrCast(name);
        }
        const handle = thread.getHandle();
        return try std.fmt.bufPrintZ(buf, "{}", .{handle});
    }
    return &self.name_buf;
}

pub fn setName(
    self: *SystemThreadWorker,
    name: [:0]const u8,
) !void {
    if (self.handle) |thread| {
        try thread.setName(name);
        return;
    }
    std.mem.copyForwards(u8, &self.name_buf, name);
}

pub fn systemThreadWorker() Worker {
    return .{
        .type = .thread,
        .vtable = .{
            .@"suspend" = @ptrCast(&@"suspend"),
            .@"resume" = @ptrCast(&@"resume"),
            .getName = @ptrCast(&getName),
            .setName = @ptrCast(&setName),
        },
        .ptr = &this_,
    };
}
