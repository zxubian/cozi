//! Container for function pointer + heap-allocated arguments
const std = @import("std");
const log = std.log.scoped(.closure);
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Runnable = @import("./runnable.zig");
const Closure = @This();

pub fn Impl(
    comptime routine: anytype,
    comptime managed: bool,
) type {
    const Args = std.meta.ArgsTuple(@TypeOf(routine));
    // TODO: refactor
    if (managed) {
        return struct {
            arguments: Args,
            allocator: Allocator,
            runnable: Runnable,

            pub fn run(ctx: *anyopaque) void {
                const closure: *@This() = @alignCast(@ptrCast(ctx));
                if (comptime returnsErrorUnion(routine)) {
                    @call(.auto, routine, closure.arguments) catch |e| {
                        std.debug.panic("Unhandled error in closure: {}", .{e});
                    };
                } else {
                    @call(.auto, routine, closure.arguments);
                }
                closure.allocator.destroy(closure);
            }
        };
    } else {
        return struct {
            arguments: Args,
            runnable: Runnable,

            pub fn init(self: *@This(), args: Args) void {
                const ClosureType = @This();
                self.* = .{
                    .arguments = args,
                    .runnable = .{
                        .runFn = ClosureType.run,
                        .ptr = self,
                    },
                };
            }

            pub fn run(ctx: *anyopaque) void {
                const self: *@This() = @alignCast(@ptrCast(ctx));
                if (comptime returnsErrorUnion(routine)) {
                    @call(.auto, routine, self.arguments) catch |e| {
                        std.debug.panic("Unhandled error in closure {}", .{e});
                    };
                } else {
                    @call(.auto, routine, self.arguments);
                }
            }
        };
    }
}

fn returnsErrorUnion(comptime routine: anytype) bool {
    const Routine = @TypeOf(routine);
    const routine_type_info = @typeInfo(Routine);
    assert(routine_type_info == .@"fn");
    assert(routine_type_info.@"fn".return_type != null);
    const ReturnType = routine_type_info.@"fn".return_type.?;
    const return_type_info = @typeInfo(ReturnType);
    return switch (return_type_info) {
        .void => false,
        .error_union => true,
        else => {
            @compileError("Return type must be void or error.");
        },
    };
}

pub fn init(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    allocator: Allocator,
) !*Impl(routine, true) {
    const ClosureType = Impl(routine, true);
    const closure = try allocator.create(ClosureType);
    closure.* = .{
        .arguments = args,
        .runnable = .{
            .runFn = ClosureType.run,
            .ptr = closure,
        },
        .allocator = allocator,
    };
    return closure;
}
