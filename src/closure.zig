//! Container for function pointer + heap-allocated arguments
const std = @import("std");
const log = std.log.scoped(.closure);
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Runnable = @import("./runnable.zig");

pub fn Closure(
    comptime routine: anytype,
) type {
    const Args = std.meta.ArgsTuple(@TypeOf(routine));
    return struct {
        const Unmanaged = @This();
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

        pub const Managed = struct {
            raw: Unmanaged,
            allocator: Allocator,
            const Self = @This();

            pub fn init(
                args: std.meta.ArgsTuple(@TypeOf(routine)),
                allocator: Allocator,
            ) !*Self {
                const closure = try allocator.create(Self);
                closure.* = .{
                    .raw = .{
                        .arguments = args,
                        .runnable = .{
                            .runFn = Self.run,
                            .ptr = closure,
                        },
                    },
                    .allocator = allocator,
                };
                return closure;
            }

            pub fn run(ctx: *anyopaque) void {
                const closure: *Self = @alignCast(@ptrCast(ctx));
                if (comptime returnsErrorUnion(routine)) {
                    @call(.auto, routine, closure.raw.arguments) catch |e| {
                        std.debug.panic("Unhandled error in closure: {}", .{e});
                    };
                } else {
                    @call(.auto, routine, closure.raw.arguments);
                }
                closure.allocator.destroy(closure);
            }

            pub inline fn runnable(self: *Self) *Runnable {
                return &self.raw.runnable;
            }
        };
    };
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
