const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Runnable = @import("./runnable.zig");

pub const ThreadPools = @import("./executors/threadPools.zig");
pub const Manual = @import("./executors/manual.zig");

pub const Executor = struct {
    vtable: Vtable,

    const Vtable = struct {
        pub const Submit = *const fn (*Executor, *Runnable) void;
        submitFn: Submit,
    };

    pub fn submit(
        self: *Executor,
        comptime func: anytype,
        args: anytype,
        allocator: Allocator,
    ) void {
        const Args = @TypeOf(args);
        const Closure = struct {
            arguments: Args,
            executor: *Executor,
            runnable: Runnable,
            allocator: Allocator,

            fn runFn(runnable: *Runnable) void {
                const closure: *@This() = @fieldParentPtr("runnable", runnable);
                @call(.auto, func, closure.arguments);
                closure.allocator.destroy(closure);
            }
        };
        // No way to recover here. Just crash.
        // Don't want to propagate the error up.
        const closure = allocator.create(Closure) catch |e| std.debug.panic(
            "Failed to allocate closure in {s}: {}",
            .{ @typeName(Executor), e },
        );
        closure.* = .{
            .arguments = args,
            .executor = self,
            .runnable = .{
                .runFn = Closure.runFn,
            },
            .allocator = allocator,
        };
        self.vtable.submitFn(self, &closure.runnable);
    }
};

test {
    _ = @import("./executors/threadPools.zig");
    _ = @import("./executors/manual.zig");
}
