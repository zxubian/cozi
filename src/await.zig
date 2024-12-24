const std = @import("std");
const Awaiter = @import("./awaiter.zig");
const Fiber = @import("./fiber.zig");

/// Generic await algorithm
/// https://lewissbaker.github.io/2017/11/17/understanding-operator-co-await
pub fn @"await"(awaitable: anytype) void {
    const awaiter: Awaiter = awaitable.awaiter();
    if (!awaiter.awaitReady()) {
        const handle = getHandle();
        handle.@"suspend"(awaiter);
    }
    return awaiter.awaitResume();
}

fn getHandle() *Fiber {
    if (Fiber.current()) |curr| {
        return curr;
    }
    std.debug.panic("TODO: support thread handles", .{});
}
