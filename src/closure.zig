//! Stackfull coroutine
const std = @import("std");
const log = std.log.scoped(.closure);
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Runnable = @import("./runnable.zig");
const Closure = @This();

fn Impl(comptime routine: anytype) type {
    return struct {
        const Args = std.meta.ArgsTuple(@TypeOf(routine));
        arguments: Args,
        allocator: Allocator,
        runnable: Runnable,

        pub fn runFn(runnable: *Runnable) void {
            const has_error_union = comptime blk: {
                const Routine = @TypeOf(routine);
                const routine_type_info = @typeInfo(Routine);
                assert(routine_type_info == .@"fn");
                assert(routine_type_info.@"fn".return_type != null);
                const ReturnType = routine_type_info.@"fn".return_type.?;
                const return_type_info = @typeInfo(ReturnType);
                break :blk switch (return_type_info) {
                    .void => false,
                    .error_union => true,
                    else => {
                        @compileError("Return type must be void or error.");
                    },
                };
            };
            const closure: *@This() = @fieldParentPtr("runnable", runnable);
            if (has_error_union) {
                @call(.auto, routine, closure.arguments) catch |e| {
                    std.debug.panic("Unhandled error in closure {}", .{e});
                };
            } else {
                @call(.auto, routine, closure.arguments);
            }
            closure.allocator.destroy(closure);
        }
    };
}

pub fn init(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    allocator: Allocator,
) !*Impl(routine) {
    const ClosureType = Impl(routine);
    const closure = try allocator.create(ClosureType);
    closure.* = .{
        .arguments = args,
        .runnable = .{
            .runFn = ClosureType.runFn,
        },
        .allocator = allocator,
    };
    return closure;
}
