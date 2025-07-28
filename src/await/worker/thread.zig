const std = @import("std");
const cozi = @import("../../root.zig");
const Awaiter = cozi.await.Awaiter;
const Worker = cozi.await.Worker;
const log = cozi.core.log.scoped(.worker);

threadlocal var name_buf: [std.Thread.max_name_len:0]u8 = [_:0]u8{0} ** std.Thread.max_name_len;
threadlocal var parking_lot: cozi.fault.stdlike.atomic.Value(u32) = .init(0);

pub inline fn worker(self: *std.Thread) Worker {
    return .{
        .ptr = self,
        .type = .thread,
        .vtable = .{
            .@"suspend" = @ptrCast(&@"suspend"),
            .@"resume" = @ptrCast(&@"resume"),
            .getName = @ptrCast(&getNameBuffered),
            .setName = @ptrCast(&setName),
        },
    };
}

fn @"suspend"(self: *std.Thread, awaiter: Awaiter) void {
    switch (awaiter.awaitSuspend(worker(self))) {
        .never_suspend => return,
        .always_suspend => {
            std.debug.print("suspend begin\n", .{});
            if (parking_lot.cmpxchgStrong(0, 1, .seq_cst, .seq_cst) == 0) {
                std.debug.print("suspend\n", .{});
                std.Thread.Futex.wait(&parking_lot, 1);
            } else {
                std.debug.print("suspend fail\n", .{});
            }
        },
        .symmetric_transfer_next => {
            std.debug.panic("System threads do not support symmetric transfer", .{});
        },
    }
}

fn @"resume"(_: *std.Thread) void {
    std.debug.print("resume\n", .{});
    _ = parking_lot.cmpxchgStrong(1, 0, .seq_cst, .seq_cst);
}

fn getNameBuffered(self: *std.Thread) [:0]const u8 {
    return getName(self, &name_buf) catch {
        return std.fmt.bufPrintZ(
            &name_buf,
            "{}",
            .{@intFromPtr(self)},
        ) catch unreachable;
    };
}

pub fn getName(
    thread: *std.Thread,
    buf: *[std.Thread.max_name_len:0]u8,
) ![:0]const u8 {
    if (thread == invalid_thread_handle) {
        return try std.fmt.bufPrintZ(
            buf,
            "{s}",
            .{"Unknown"},
        );
    }
    const maybe_name: ?[:0]const u8 = blk: {
        const name = thread.getName(buf) catch {
            break :blk null;
        };
        break :blk @ptrCast(name);
    };
    if (maybe_name) |name| {
        return name;
    } else {
        return try std.fmt.bufPrintZ(
            buf,
            "{}",
            .{thread.getHandle()},
        );
    }
}

const invalid_thread_handle: *std.Thread = @ptrFromInt(
    std.mem.alignBackwardAnyAlign(
        usize,
        std.math.maxInt(u64),
        @alignOf(std.Thread),
    ),
);

pub fn setName(
    _: *std.Thread,
    name: [:0]const u8,
) void {
    std.mem.copyForwards(u8, &name_buf, name);
}

pub fn systemThreadWorker() Worker {
    log.warn("unknown (system) thread", .{});
    return .{
        .type = .thread,
        .vtable = .{
            .@"suspend" = @ptrCast(&@"suspend"),
            .@"resume" = @ptrCast(&@"resume"),
            .getName = @ptrCast(&getNameBuffered),
            .setName = @ptrCast(&setName),
        },
        .ptr = invalid_thread_handle,
    };
}
