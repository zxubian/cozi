const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../root.zig");
const Awaiter = cozi.await.Awaiter;
const Worker = cozi.await.Worker;
const log = cozi.core.log.scoped(.worker);
const SystemThreadWorker = @This();

threadlocal var this_: SystemThreadWorker = .{};

name_buf: [std.Thread.max_name_len:0]u8 = [_:0]u8{0} ** std.Thread.max_name_len,
print_buf: [std.Thread.max_name_len:0]u8 = [_:0]u8{0} ** std.Thread.max_name_len,
state: cozi.fault.stdlike.atomic.Value(u32) = .init(@intFromEnum(State.running)),
handle: ?*std.Thread = null,

pub const State = enum(u32) {
    suspended = 0,
    running = 1,
    _,
};

pub fn init(
    handle: *std.Thread,
    name: [:0]const u8,
) !Worker {
    this_.handle = handle;
    try setName(&this_, name);
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
            log.debug("[{s}] suspend begin", .{getName(self)});
            switch (@as(State, @enumFromInt(self.state.fetchSub(1, .seq_cst)))) {
                .suspended => {
                    @branchHint(.unlikely);
                    std.debug.panic(
                        "[{s}] invalid state transition: suspending twice",
                        .{
                            getName(self),
                        },
                    );
                },
                .running => {
                    log.debug(
                        "[{s}] Setting state to sleep {*} -> {}",
                        .{
                            self.getName(),
                            &self.state,
                            @intFromEnum(State.suspended),
                        },
                    );
                    while (self.state.load(.seq_cst) == @intFromEnum(State.suspended)) {
                        std.Thread.Futex.wait(
                            &self.state,
                            @intFromEnum(State.suspended),
                        );
                    }
                    assert(self.state.load(.seq_cst) > 0);
                    log.debug(
                        "[{s}] Woke up from sleep",
                        .{self.getName()},
                    );
                },
                else => {},
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
    log.debug(
        "[{s}] resuming: {*} -> {}",
        .{
            getName(other),
            &other.state,
            @intFromEnum(State.running),
        },
    );
    if (other.state.fetchAdd(1, .seq_cst) == 0) {
        std.Thread.Futex.wake(&other.state, 1);
    }
}

pub fn getName(self: *SystemThreadWorker) [:0]const u8 {
    return getNameWithBuffer(self, &this_.print_buf) catch unreachable;
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
