const std = @import("std");
const Thread = @This();

threadlocal var current_thread: ?*std.Thread = null;

pub fn setCurrentThread(thread: ?*std.Thread) void {
    current_thread = thread;
}

pub fn getCurrentThread() ?*std.Thread {
    return current_thread;
}

pub fn nameOrHandle(
    thread: *std.Thread,
    buf: *[std.Thread.max_name_len:0]u8,
) ![:0]const u8 {
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
