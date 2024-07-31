const std = @import("std");
const assert = std.debug.assert;

pub const ThreadPool = @import("./executors/threadPool.zig");

pub const Runnable = struct {
    runFn: RunProto,
    pub const RunProto = *const fn (runnable: *Runnable) void;
};

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
        allocator: std.mem.Allocator,
    ) void {
        const Args = @TypeOf(args);
        const Closure = struct {
            arguments: Args,
            executor: *Executor,
            runnable: Runnable,
            allocator: std.mem.Allocator,

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
    _ = @import("./executors/threadPool.zig");
}
