const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const Atomic = std.atomic.Value;

const LockFree = @import("../lockFree.zig");
const Stack = LockFree.MpscLockFreeStack;
const Queue = LockFree.MpscLockFreeQueue;
const Executors = @import("../../../executors.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const Fiber = @import("../../../fiber.zig");

test "stack - basic" {
    const Node = struct {
        intrusive_list_node: Stack(@This()).Node,
        data: usize = 0,
    };
    const node_count = 100;
    var nodes: [node_count]Node = undefined;
    var stack: Stack(Node) = .{};
    for (&nodes, 0..) |*node, i| {
        node.*.data = i;
        stack.pushFront(node);
    }
    try testing.expectEqual(node_count, stack.count.load(.seq_cst));
    var i: usize = 0;
    var array_idx: isize = node_count - 1;
    while (stack.popFront()) |node| : ({
        i += 1;
        array_idx -= 1;
    }) {
        try testing.expectEqual(nodes[@intCast(array_idx)].data, node.data);
    }
    try testing.expectEqual(node_count, i);
}

test "stack - multiple producers - manual" {
    var manual_executor: ManualExecutor = .{};
    const Node = struct {
        intrusive_list_node: Stack(@This()).Node,
        data: usize = 0,
    };
    const fiber_count = 100;
    const node_per_fiber = 100;
    const node_count = fiber_count * node_per_fiber;
    var nodes: [node_count]Node = undefined;
    const Ctx = struct {
        stack: Stack(Node),
        counter: Atomic(usize) = .init(0),
        nodes: []Node,

        pub fn run(ctx: *@This()) void {
            for (0..node_per_fiber) |_| {
                const counter = ctx.counter.fetchAdd(1, .seq_cst);
                const node: *Node = &ctx.nodes[counter];
                node.*.data = counter;
                ctx.stack.pushFront(node);
            }
        }
    };
    var ctx: Ctx = .{
        .stack = .{},
        .nodes = &nodes,
    };
    for (0..fiber_count) |_| {
        try Fiber.go(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            manual_executor.executor(),
        );
    }
    _ = manual_executor.drain();
    try testing.expectEqual(node_count, ctx.stack.count.load(.seq_cst));
    var i: usize = 0;
    var array_idx: isize = node_count - 1;
    while (ctx.stack.popFront()) |node| : ({
        i += 1;
        array_idx -= 1;
    }) {
        try testing.expectEqual(nodes[@intCast(array_idx)].data, node.data);
    }
    try testing.expectEqual(node_count, i);
}

test "stack - multiple producers - thread pool" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Node = struct {
        intrusive_list_node: Stack(@This()).Node,
        data: usize = 0,
    };
    const fiber_count = 500;
    const node_per_fiber = 500;
    const node_count = fiber_count * node_per_fiber;
    var nodes: [node_count]Node = undefined;
    const Ctx = struct {
        stack: Stack(Node),
        counter: Atomic(usize) = .init(0),
        nodes: []Node,

        pub fn run(ctx: *@This()) void {
            for (0..node_per_fiber) |_| {
                const counter = ctx.counter.fetchAdd(1, .seq_cst);
                const node: *Node = &ctx.nodes[counter];
                node.*.data = counter;
                ctx.stack.pushFront(node);
            }
        }
    };
    var ctx: Ctx = .{
        .stack = .{},
        .nodes = &nodes,
    };
    for (0..fiber_count) |_| {
        try Fiber.go(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }
    tp.waitIdle();
    try testing.expectEqual(node_count, ctx.stack.count.load(.seq_cst));
    var i: usize = 0;
    var array_idx: isize = node_count - 1;
    while (ctx.stack.popFront()) |node| : ({
        i += 1;
        array_idx -= 1;
    }) {
        try testing.expectEqual(nodes[@intCast(array_idx)].data, node.data);
    }
    try testing.expectEqual(node_count, i);
}

test "stack - stress" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Node = struct {
        intrusive_list_node: Stack(@This()).Node = .{},
        data: usize = 0,
        touched_by_producer: bool = false,
        touched_by_consumer: bool = false,
    };
    const producer_count = 100;
    const node_per_fiber = 100;
    const node_count = producer_count * node_per_fiber;
    var nodes: [node_count]Node = [_]Node{.{}} ** node_count;
    const Ctx = struct {
        stack: Stack(Node),
        counter: Atomic(usize) = .init(0),
        nodes: []Node,
        producers_done: [producer_count]bool = undefined,
        consumer_done: bool = false,
        mutex: Fiber.Mutex = .{},
        consumer_counter: usize = 0,

        pub fn producer(ctx: *@This(), i: usize) void {
            ctx.producers_done[i] = false;
            for (0..node_per_fiber) |_| {
                const counter = ctx.counter.fetchAdd(1, .seq_cst);
                const node: *Node = &ctx.nodes[counter];
                node.*.data = counter;
                node.*.touched_by_producer = true;
                ctx.stack.pushFront(node);
                Fiber.yield();
            }
            {
                ctx.mutex.lock();
                defer ctx.mutex.unlock();
                ctx.producers_done[i] = true;
            }
        }

        pub fn consumer(ctx: *@This()) void {
            while (!ctx.all_producers_done(true)) {
                while (ctx.stack.popFront()) |*node| {
                    ctx.consumer_counter += node.*.data;
                    node.*.touched_by_consumer = true;
                }
                Fiber.yield();
            }
            while (ctx.stack.popFront()) |node| {
                ctx.consumer_counter += node.data;
                node.*.touched_by_consumer = true;
            }
            ctx.consumer_done = true;
        }

        pub fn all_producers_done(ctx: *@This(), comptime lock: bool) bool {
            if (lock) {
                ctx.mutex.lock();
                defer ctx.mutex.unlock();
            }
            for (ctx.producers_done) |done| {
                if (!done) {
                    return false;
                }
            }
            return true;
        }
    };
    var ctx: Ctx = .{
        .stack = .{},
        .nodes = &nodes,
        .producers_done = [_]bool{false} ** producer_count,
    };
    try Fiber.go(
        Ctx.consumer,
        .{&ctx},
        testing.allocator,
        tp.executor(),
    );
    for (0..producer_count) |i| {
        try Fiber.go(
            Ctx.producer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
        );
    }
    tp.waitIdle();
    const target = comptime blk: {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var i: usize = 0;
        var c: usize = 0;
        for (0..producer_count) |_| {
            for (0..node_per_fiber) |_| {
                c += i;
                i += 1;
            }
        }
        break :blk c;
    };
    try testing.expect(ctx.all_producers_done(false));
    try testing.expect(ctx.consumer_done);
    for (ctx.nodes) |node| {
        try testing.expect(node.touched_by_producer);
        try testing.expect(node.touched_by_consumer);
    }
    try testing.expectEqual(target, ctx.consumer_counter);
}

test "queue - basic" {
    const Node = struct {
        intrusive_list_node: Stack(@This()).Node,
        data: usize = 0,
    };
    const node_count = 100;
    var nodes: [node_count]Node = undefined;
    var queue: Queue(Node) = .{};
    for (&nodes, 0..) |*node, i| {
        node.*.data = i;
        queue.pushBack(node);
    }
    try testing.expectEqual(node_count, queue.count.load(.seq_cst));
    var i: usize = 0;
    while (queue.popFront()) |node| : (i += 1) {
        try testing.expectEqual(i, node.data);
    }
    try testing.expectEqual(node_count, i);
}

test "queue - multiple producers - manual" {
    var manual_executor: ManualExecutor = .{};
    const Node = struct {
        intrusive_list_node: Stack(@This()).Node,
        data: usize = 0,
    };
    const fiber_count = 100;
    const node_per_fiber = 100;
    const node_count = fiber_count * node_per_fiber;
    var nodes: [node_count]Node = undefined;
    const Ctx = struct {
        queue: Queue(Node),
        counter: Atomic(usize) = .init(0),
        nodes: []Node,

        pub fn run(ctx: *@This()) void {
            for (0..node_per_fiber) |_| {
                const counter = ctx.counter.fetchAdd(1, .seq_cst);
                const node: *Node = &ctx.nodes[counter];
                node.*.data = counter;
                ctx.queue.pushBack(node);
            }
        }
    };
    var ctx: Ctx = .{
        .queue = .{},
        .nodes = &nodes,
    };
    for (0..fiber_count) |_| {
        try Fiber.go(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            manual_executor.executor(),
        );
    }
    _ = manual_executor.drain();
    try testing.expectEqual(node_count, ctx.queue.count.load(.seq_cst));
    var i: usize = 0;
    while (ctx.queue.popFront()) |node| : (i += 1) {
        try testing.expectEqual(i, node.data);
    }
    try testing.expectEqual(node_count, i);
}

test "queue - multiple producers - thread pool" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Node = struct {
        intrusive_list_node: Stack(@This()).Node,
        data: usize = 0,
    };
    const fiber_count = 100;
    const node_per_fiber = 100;
    const node_count = fiber_count * node_per_fiber;
    var nodes: [node_count]Node = undefined;
    const Ctx = struct {
        queue: Queue(Node),
        counter: Atomic(usize) = .init(0),
        nodes: []Node,

        pub fn run(ctx: *@This()) void {
            for (0..node_per_fiber) |_| {
                const counter = ctx.counter.fetchAdd(1, .seq_cst);
                const node: *Node = &ctx.nodes[counter];
                node.*.data = counter;
                ctx.queue.pushBack(node);
            }
        }
    };
    var ctx: Ctx = .{
        .queue = .{},
        .nodes = &nodes,
    };
    for (0..fiber_count) |_| {
        try Fiber.go(
            Ctx.run,
            .{&ctx},
            testing.allocator,
            tp.executor(),
        );
    }
    tp.waitIdle();
    try testing.expectEqual(node_count, ctx.queue.count.load(.seq_cst));
    var i: usize = 0;
    while (ctx.queue.popFront()) |node| : (i += 1) {
        try testing.expectEqual(i, node.data);
    }
    try testing.expectEqual(node_count, i);
}

test "queue - stress" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Node = struct {
        intrusive_list_node: Stack(@This()).Node = .{},
        data: usize = 0,
        touched_by_producer: bool = false,
        touched_by_consumer: bool = false,
    };
    const producer_count = 1000;
    const node_per_fiber = 1000;
    const node_count = producer_count * node_per_fiber;
    var nodes: [node_count]Node = [_]Node{.{}} ** node_count;
    const Ctx = struct {
        queue: Queue(Node),
        counter: Atomic(usize) = .init(0),
        nodes: []Node,
        producers_done: [producer_count]bool = undefined,
        consumer_done: bool = false,
        mutex: Fiber.Mutex = .{},

        pub fn producer(ctx: *@This(), i: usize) void {
            ctx.producers_done[i] = false;
            for (0..node_per_fiber) |_| {
                const counter = ctx.counter.fetchAdd(1, .seq_cst);
                const node: *Node = &ctx.nodes[counter];
                node.*.data = counter;
                node.*.touched_by_producer = true;
                ctx.queue.pushBack(node);
                Fiber.yield();
            }
            {
                ctx.mutex.lock();
                defer ctx.mutex.unlock();
                ctx.producers_done[i] = true;
            }
        }

        pub fn consumer(ctx: *@This()) !void {
            var counter: usize = 0;
            while (!ctx.all_producers_done(true)) {
                while (ctx.queue.popFront()) |node| : (counter += 1) {
                    try testing.expectEqual(counter, node.data);
                    node.*.touched_by_consumer = true;
                }
                Fiber.yield();
            }
            while (ctx.queue.popFront()) |node| : (counter += 1) {
                try testing.expectEqual(counter, node.data);
                node.*.touched_by_consumer = true;
            }
            ctx.consumer_done = true;
        }

        pub fn all_producers_done(ctx: *@This(), comptime lock: bool) bool {
            if (lock) {
                ctx.mutex.lock();
                defer ctx.mutex.unlock();
            }
            for (ctx.producers_done) |done| {
                if (!done) {
                    return false;
                }
            }
            return true;
        }
    };
    var ctx: Ctx = .{
        .queue = .{},
        .nodes = &nodes,
        .producers_done = [_]bool{false} ** producer_count,
    };
    try Fiber.go(
        Ctx.consumer,
        .{&ctx},
        testing.allocator,
        tp.executor(),
    );
    for (0..producer_count) |i| {
        try Fiber.go(
            Ctx.producer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
        );
    }
    tp.waitIdle();
    try testing.expect(ctx.all_producers_done(false));
    try testing.expect(ctx.consumer_done);
    for (ctx.nodes) |node| {
        try testing.expect(node.touched_by_producer);
        try testing.expect(node.touched_by_consumer);
    }
}
