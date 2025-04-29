const std = @import("std");

const cozi = @import("../../root.zig");
pub const Awaiter = @import("./awaiter.zig");
const Fiber = cozi.Fiber;
const log = cozi.core.log.scoped(.@"await");

/// Generic await algorithm
/// https://lewissbaker.github.io/2017/11/17/understanding-operator-co-await
pub fn @"await"(expr_ptr: anytype) awaitReturnType(getAwaitableType(@TypeOf(expr_ptr.*))) {
    const Expr = @TypeOf(expr_ptr.*);
    const Awaitable = getAwaitableType(Expr);
    const awaitable: *Awaitable = getAwaitable(expr_ptr);
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

fn getAwaitableType(Expr: type) type {
    if (@hasDecl(Expr, "awaitable")) {
        const type_info: std.builtin.Type.Fn = @typeInfo(@TypeOf(Expr.awaitable)).@"fn";
        return type_info.return_type.?;
    }
    return Expr;
}

inline fn getAwaitable(expr_ptr: anytype) *getAwaitableType(@TypeOf(expr_ptr.*)) {
    const Expr = @TypeOf(expr_ptr.*);
    if (@hasDecl(Expr, "awaitable")) {
        var awaitable = expr_ptr.awaitable();
        return &awaitable;
    }
    return expr_ptr;
}

fn awaitReturnType(Awaitable: type) type {
    switch (@typeInfo(@TypeOf(Awaitable.awaitResume))) {
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
    std.debug.panic("`await` is only supported in Fiber context", .{});
}
