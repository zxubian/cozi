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

    const iterations = 3;
    const Ctx = struct {
        pub fn run(ctx: *Coroutine) void {
            log.debug("coroutine started", .{});
            for (0..iterations) |_| {
                log.debug("about to suspend", .{});
                ctx.@"suspend"();
                log.debug("resumed", .{});
            }
        }
    };

    var coro: Coroutine.Managed = undefined;
    try coro.initInPlace(Ctx.run, .{&coro.coroutine}, gpa.allocator());
    defer coro.deinit();
    for (0..iterations) |_| {
        log.debug("about to resume", .{});
        coro.@"resume"();
        log.debug("suspended", .{});
    }
    assert(!coro.isCompleted());
    coro.@"resume"();
    assert(coro.isCompleted());
}
