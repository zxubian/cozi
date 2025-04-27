const std = @import("std");

const cozi = @import("../../root.zig");
pub const Awaiter = @import("./awaiter.zig");
// TODO: eliminate dependency on fiber here
const Fiber = cozi.Fiber;
const log = cozi.core.log.scoped(.@"await");

/// Generic await algorithm
/// https://lewissbaker.github.io/2017/11/17/understanding-operator-co-await
pub fn @"await"(awaitable: anytype) awaitReturnType(@TypeOf(awaitable.*)) {
    // for awaitables that always return false,
    // want to resolve optimize this branch out,
    // so rely on duck-typing here
    if (!awaitable.awaitReady()) {
        // need to handle to Fiber, so use type-erased
        // awaiter here:
        const awaiter: Awaiter = awaitable.awaiter();
        const handle = getHandle();
        log.debug("{s} about to suspend due to {s}", .{ handle.name, @typeName(@TypeOf(awaitable)) });
        handle.@"suspend"(awaiter);
        // --- resume ---
        return awaitable.awaitResume(true);
    }
    // need to resolve return type at comptime
    // so rely on duck-typing here
    return awaitable.awaitResume(false);
}

fn awaitReturnType(awaitable_type: type) type {
    switch (@typeInfo(@TypeOf(awaitable_type.awaitResume))) {
        .@"fn" => |f| {
            return f.return_type.?;
        },
        else => @compileError("can only be used with function types"),
    }
}

fn getHandle() *Fiber {
    if (Fiber.current()) |curr| {
        return curr;
    }
    std.debug.panic("TODO: support thread handles", .{});
}
