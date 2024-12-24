const std = @import("std");
const Atomic = std.atomic.Value;
const Strand = @This();
const Runnable = @import("../../runnable.zig");
const Closure = @import("../../closure.zig");
const Containers = @import("../../containers.zig");
const Intrusive = Containers.Intrusive;
const Queue = Intrusive.LockFree.MpscQueue;
const Await = @import("../../await.zig").@"await";
const Awaiter = @import("../../awaiter.zig");
const Fiber = @import("../../fiber.zig");

const log = std.log.scoped(.fiber_strand);

queue: Queue(Node) = .{},
owner: Atomic(?*Fiber) = .init(null),

const Node = struct {
    intrusive_list_node: Intrusive.Node = .{},
    submitting_fiber: *Fiber,
    critical_section_runnable: *Runnable,
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
        // place awaiter on Fiber stack
        var strand_awaiter: StrandAwaiter = .{
            .strand = self,
            .node = &node,
            .submitting_fiber = current_fiber,
        };
        Await(&strand_awaiter);
        // ------ Fiber resumes from suspend ------
        if (self.owner.load(.seq_cst) == current_fiber) {
            self.runBatch(current_fiber);
        }
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
                node.submitting_fiber.beginSuspendIllegalScope();
                defer node.submitting_fiber.endSuspendIllegalScope();
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
    if (self.owner.cmpxchgStrong(
        executing_fiber,
        null,
        .seq_cst,
        .seq_cst,
    )) |actual_owner| {
        std.debug.panic(
            "Owner changed! Expected: {*} Actual: {*}",
            .{ executing_fiber, actual_owner },
        );
    }
}

const StrandAwaiter = struct {
    strand: *Strand,
    node: *Node,
    submitting_fiber: *Fiber,

    pub fn awaitReady(ctx: *anyopaque) bool {
        const self: *StrandAwaiter = @alignCast(@ptrCast(ctx));
        self.strand.queue.pushBack(self.node);
        return self.strand.owner.cmpxchgStrong(
            null,
            self.submitting_fiber,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    pub fn awaitSuspend(
        ctx: *anyopaque,
        handle: *anyopaque,
    ) Awaiter.AwaitSuspendResult {
        const self: *StrandAwaiter = @alignCast(@ptrCast(ctx));
        const fiber: *Fiber = @alignCast(@ptrCast(handle));
        if (self.strand.owner.cmpxchgStrong(
            null,
            fiber,
            .seq_cst,
            .seq_cst,
        ) == null) {
            return Awaiter.AwaitSuspendResult{ .never_suspend = {} };
        }
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }

    pub fn awaitResume(_: *anyopaque) void {}

    pub fn awaiter(self: *StrandAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{
                .await_suspend = awaitSuspend,
                .await_resume = awaitResume,
                .await_ready = awaitReady,
            },
        };
    }
};

test {
    _ = @import("./strand/tests.zig");
}
