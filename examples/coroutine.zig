const std = @import("std");
const zinc = @import("zinc");
const Coroutine = zinc.Coroutine;
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const log = std.log.scoped(.example);

    defer {
        if (gpa.detectLeaks()) {
            unreachable;
        }
    }

    const Ctx = struct {
        pub fn run(ctx: *Coroutine) void {
            log.debug("step 1", .{});
            ctx.@"suspend"();
            log.debug("step 2", .{});
            ctx.@"suspend"();
            log.debug("step 3", .{});
        }
    };

    var coro: Coroutine.Managed = undefined;
    try coro.initInPlace(Ctx.run, .{&coro.coroutine}, gpa.allocator());
    defer coro.deinit();
    for (0..3) |_| {
        coro.@"resume"();
    }
    assert(coro.isCompleted());
}
