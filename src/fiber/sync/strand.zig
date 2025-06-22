const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const cozi = @import("../../root.zig");
const fault = cozi.fault;
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const core = cozi.core;
const Runnable = core.Runnable;
const Closure = core.Closure;
const Fiber = cozi.Fiber;
const generic_await = cozi.@"await";
const Await = generic_await.@"await";
const Awaiter = generic_await.Awaiter;
const Worker = generic_await.Worker;
const containers = cozi.containers;
const intrusive = containers.intrusive;
const Queue = intrusive.lock_free.MpscQueue;
const Stack = intrusive.lock_free.MpscStack;

const Strand = @This();

const log = cozi.core.log.scoped(.fiber_strand);

tasks: Queue(TaskNode) = .{},
count: Atomic(usize) = .init(0),

const State = enum(usize) {
    idle = 0,
    // tail of queue
    _,
};

const TaskNode = struct {
    intrusive_list_node: intrusive.Node = .{},
    submitting_fiber: *Fiber,
    critical_section_runnable: *Runnable,
    const Self = @This();
};

const OwnerNode = struct {
    intrusive_list_node: intrusive.Node = .{},
    fiber: *Fiber,
    const Self = @This();

    pub fn getNext(self: *Self) ?*Self {
        if (self.intrusive_list_node.next) |next_intrusive_ptr| {
            return next_intrusive_ptr.parentPtr(Self);
        }
        return null;
    }

    pub fn setNext(self: *Self, next: ?*Self) void {
        const next_intrusive_ptr = if (next) |n| &n.intrusive_list_node else null;
        self.intrusive_list_node.next = next_intrusive_ptr;
    }

    pub fn head(self: *Self) struct { head: *Self, previous: *Self } {
        var previous = self;
        var current: *Self = self;
        while (current.getNext()) |next| : ({
            previous = current;
            current = next;
        }) {}
        return .{
            .head = current,
            .previous = previous,
        };
    }
};

pub fn combine(
    self: *Strand,
    func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) void {
    if (Fiber.current()) |current_fiber| {
        // allocate closure on fiber stack
        var critical_section_closure: Closure(func) = undefined;
        critical_section_closure.init(args);
        var task_node: TaskNode = .{
            .submitting_fiber = current_fiber,
            .critical_section_runnable = &critical_section_closure.runnable,
        };
        // place awaiter on Fiber stack
        var strand_awaiter: StrandAwaiter = .{
            .strand = self,
            .node = &task_node,
        };
        const is_owner = self.count.fetchAdd(1, .seq_cst) == 0;
        if (is_owner) {
            log.debug("{s}: became owner. Will run own cs.", .{current_fiber.name});
            runCriticalSection(&task_node, current_fiber);
            while (self.count.cmpxchgWeak(1, 0, .seq_cst, .seq_cst)) |count| {
                log.debug(
                    "{s}: saw {} tasks registered. Will run batch.",
                    .{ current_fiber.name, count },
                );
                self.runBatch(current_fiber);
            }
        } else {
            log.debug(
                "{s}: could not become owner. Will add self to queue and suspend now",
                .{current_fiber.name},
            );
            Await(&strand_awaiter);
            // ------ Fiber resumes from suspend ------
            _ = self.count.fetchSub(1, .seq_cst);
        }
    } else {
        std.debug.panic("Can only call Strand.combine while executing inside of a Fiber", .{});
    }
}

fn assertEqual(expected: anytype, actual: anytype) void {
    if (expected != actual) {
        log.err("Expected: {}. Actual: {}", .{ expected, actual });
    }
    assert(expected == actual);
}

fn runCriticalSection(node: *TaskNode, executing_fiber: *Fiber) void {
    executing_fiber.beginSuspendIllegalScope();
    defer executing_fiber.endSuspendIllegalScope();
    log.debug(
        "{s}: executing critical section submitted by {s}",
        .{ executing_fiber.name, node.submitting_fiber.name },
    );
    node.critical_section_runnable.run();
}

fn runBatch(self: *Strand, executing_fiber: *Fiber) void {
    log.debug("{s}: starting runBatchloop", .{executing_fiber.name});
    var schedule_queue: Queue(TaskNode) = .{};
    const Callback = struct {
        executing_fiber: *Fiber,
        schedule_queue: *Queue(TaskNode),
        pub fn run(next: *TaskNode, ctx: *anyopaque) void {
            const cb: *@This() = @alignCast(@ptrCast(ctx));
            runCriticalSection(next, cb.executing_fiber);
            log.debug(
                "{s}: pushing {s} to schedule queue.",
                .{
                    cb.executing_fiber.name,
                    next.submitting_fiber.name,
                },
            );
            assert(cb.executing_fiber != next.submitting_fiber);
            cb.schedule_queue.pushBack(next);
        }
    };
    var callback: Callback = .{
        .executing_fiber = executing_fiber,
        .schedule_queue = &schedule_queue,
    };
    self.tasks.consumeAll(Callback.run, &callback);
    const submit_all = struct {
        pub fn run(next: *TaskNode, _: *anyopaque) void {
            log.debug(
                "{s}: considering whether to schedule {s}",
                .{
                    Fiber.current().?.name,
                    next.submitting_fiber.name,
                },
            );
            next.submitting_fiber.scheduleSelf();
        }
    }.run;
    schedule_queue.consumeAll(submit_all, &schedule_queue);
}

const StrandAwaiter = struct {
    strand: *Strand,
    node: *TaskNode,

    // --- type-erased awaiter interface ---
    pub fn awaitSuspend(
        self: *@This(),
        worker: Worker,
    ) Awaiter.AwaitSuspendResult {
        //TODO: support threads?
        assert(worker.type == .fiber);
        self.strand.tasks.pushBack(self.node);
        return Awaiter.AwaitSuspendResult{ .always_suspend = {} };
    }

    pub fn awaiter(self: *StrandAwaiter) Awaiter {
        return Awaiter{
            .ptr = self,
            .vtable = .{ .await_suspend = @ptrCast(&awaitSuspend) },
        };
    }

    // --- comptime awaiter interface ---
    pub fn awaitReady(_: *StrandAwaiter) bool {
        return false;
    }

    pub fn awaitResume(_: *StrandAwaiter, _: bool) void {}
};

test {
    _ = @import("./strand/tests.zig");
}
