const std = @import("std");
const Atomic = std.atomic.Value;
const Strand = @This();
const Runnable = @import("../runnable.zig");
const Closure = @import("../closure.zig");
const Containers = @import("../containers.zig");
const Intrusive = Containers.Intrusive;
const Queue = Intrusive.LockFree.MpscLockFreeQueue;
const AtomicEnum = @import("../atomic_enum.zig").Value;
const Awaiter = @import("./awaiter.zig");
const Fiber = @import("../fiber.zig");
const SuspendIllegalScope = Fiber.SuspendIllegalScope;

const log = std.log.scoped(.fiber_strand);

const State = enum(u8) {
    unlocked,
    locked,
};

queue: Queue(Node) = .{},
owner: Atomic(?*Fiber) = .init(null),

const Node = struct {
    intrusive_list_node: Intrusive.Node = .{},
    submitting_fiber: *Fiber,
    critical_section_runnable: *Runnable,
};

const StrandAwaiter = struct {
    awaiter: Awaiter,
    strand: *Strand,
    node: *Node,
};

pub fn combine(
    self: *Strand,
    func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) void {
    if (Fiber.current()) |current_fiber| {
        // allocate closure on fiber stack
        var critical_section_closure: Closure.Impl(func, false) = undefined;
        critical_section_closure.init(args);
        var node: Node = .{
            .submitting_fiber = current_fiber,
            .critical_section_runnable = &critical_section_closure.runnable,
        };
        if (self.owner.cmpxchgStrong(
            null,
            current_fiber,
            .seq_cst,
            .seq_cst,
        ) == null) {
            // <=> got the lock
            // <=> will execute the batch
            _ = self.queue.pushBack(&node);
            self.runBatch(current_fiber);
            return;
        }
        // <=> didn't get the lock
        // <=> suspend & wait for somebody else to wake us up
        var awaiter: StrandAwaiter = .{
            .awaiter = .{
                .vtable = .{
                    .@"await" = Strand.@"await",
                },
                .ptr = undefined,
            },
            .strand = self,
            .node = &node,
        };
        // this is safe because combine  will not exit
        // during Fiber.suspend, so the stack will not be reused.
        awaiter.awaiter.ptr = &awaiter;
        Fiber.@"suspend"(&awaiter.awaiter);
        if (self.owner.load(.seq_cst) == current_fiber) {
            self.runBatch(current_fiber);
        }
        // ------ Fiber resumes from suspend ------
    } else {
        std.debug.panic("Can only call Strand.combine while executing inside of a Fiber", .{});
    }
}

fn runBatch(
    self: *Strand,
    executing_fiber: *Fiber,
) void {
    const Ctx = struct {
        executing_fiber: *Fiber,
        pub fn handler(node: *Node, ctx_opaque: *anyopaque) void {
            const ctx: *@This() = @alignCast(@ptrCast(ctx_opaque));
            {
                var scope: SuspendIllegalScope = .{ .fiber = ctx.executing_fiber };
                scope.Begin();
                defer scope.End();
                node.critical_section_runnable.run();
            }
            if (node.submitting_fiber != ctx.executing_fiber) {
                node.submitting_fiber.scheduleSelf();
            }
        }
    };
    var ctx: Ctx = .{
        .executing_fiber = executing_fiber,
    };
    self.queue.consumeAll(Ctx.handler, &ctx);
    if (self.owner.cmpxchgStrong(executing_fiber, null, .seq_cst, .seq_cst)) |actual_owner| {
        std.debug.panic(
            "Owner changed! Expected: {*} Actual: {*}",
            .{ executing_fiber, actual_owner },
        );
    }
}

pub fn @"await"(ctx: *anyopaque, fiber: *Fiber) void {
    const awaiter: *StrandAwaiter = @alignCast(@ptrCast(ctx));
    var self = awaiter.strand;
    _ = self.queue.pushBack(awaiter.node);
    if (self.owner.cmpxchgStrong(null, fiber, .seq_cst, .seq_cst) == null) {
        fiber.scheduleSelf();
    }
}

test {
    _ = @import("./strand/tests.zig");
}
