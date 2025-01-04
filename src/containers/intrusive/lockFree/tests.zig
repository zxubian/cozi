const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const build_config = @import("build_config");
const Atomic = std.atomic.Value;

const Containers = @import("../../../containers.zig");
const LockFree = Containers.Intrusive.LockFree;
const Stack = LockFree.MpscStack;
const Queue = LockFree.MpscQueue;
const Executors = @import("../../../executors.zig");
const ManualExecutor = Executors.Manual;
const ThreadPool = Executors.ThreadPools.Compute;
const WaitGroup = std.Thread.WaitGroup;
const Fiber = @import("../../../fiber.zig");

test "stack - basic" {
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    const Node = struct {
        intrusive_list_node: Containers.Intrusive.Node = .{},
        data: usize = 0,
    };
    const node_count = 100;
    var nodes: [node_count]Node = [_]Node{.{}} ** node_count;
    var stack: Stack(Node) = .{};
    for (&nodes, 0..) |*node, i| {
        node.*.data = i;
        stack.pushFront(node);
    }
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
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var manual_executor: ManualExecutor = .{};
    const Node = struct {
        intrusive_list_node: Containers.Intrusive.Node = .{},
        data: usize = 0,
    };
    const fiber_count = 100;
    const node_per_fiber = 100;
    const node_count = fiber_count * node_per_fiber;
    var nodes: [node_count]Node = [_]Node{.{}} ** node_count;
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
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    const cpu_count = try std.Thread.getCpuCount();
    const worker_count = if (@import("build_config").sanitize == .none) cpu_count else 4;
    var tp = try ThreadPool.init(worker_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Node = struct {
        intrusive_list_node: Containers.Intrusive.Node = .{},
        local_order: usize = 0,
        producer_idx: usize = 0,
        touched_by_producer: Atomic(bool) = .init(false),
        touched_by_consumer: Atomic(bool) = .init(false),
    };
    const count = 100;
    const producer_count = count;
    const node_per_fiber = count;
    const node_count = producer_count * node_per_fiber;
    const nodes = try testing.allocator.alloc(Node, node_count);
    defer testing.allocator.free(nodes);
    for (nodes) |*node| {
        node.* = .{};
    }
    const observed_orders = try testing.allocator.alloc(std.ArrayList(usize), producer_count);
    const producers_done = try testing.allocator.alloc(Atomic(bool), producer_count);
    for (producers_done) |*done| {
        done.* = Atomic(bool).init(false);
    }
    defer testing.allocator.free(observed_orders);
    defer testing.allocator.free(producers_done);
    const Ctx = struct {
        stack: Stack(Node),
        counter: Atomic(usize) = .init(0),
        nodes: []Node,
        producers_done: []Atomic(bool),
        consumer_done: bool = false,
        wait_group: WaitGroup = .{},
        observed_orders: []std.ArrayList(usize),

        pub fn producer(ctx: *@This(), producer_idx: usize) void {
            for (0..node_per_fiber) |i| {
                const node_idx = node_per_fiber * producer_idx + i;
                const node: *Node = &ctx.nodes[node_idx];
                if (node.touched_by_producer.cmpxchgStrong(
                    false,
                    true,
                    .seq_cst,
                    .seq_cst,
                ) != null) {
                    std.debug.panic("Node was already touched by producer", .{});
                }
                node.local_order = i;
                node.producer_idx = producer_idx;
                ctx.stack.pushFront(node);
                Fiber.yield();
            }
            if (ctx.producers_done[producer_idx].cmpxchgStrong(
                false,
                true,
                .seq_cst,
                .seq_cst,
            ) != null) {
                std.debug.panic("Done flag was already touched by producer", .{});
            }
            ctx.wait_group.finish();
        }

        pub fn consumer(ctx: *@This()) !void {
            while (true) {
                while (ctx.stack.popFront()) |*node| {
                    try testing.expect(node.*.touched_by_producer.load(.seq_cst));
                    ctx.observed_orders[node.*.producer_idx].appendAssumeCapacity(node.*.local_order);
                    if (node.*.touched_by_consumer.cmpxchgStrong(
                        false,
                        true,
                        .seq_cst,
                        .seq_cst,
                    ) != null) {
                        std.debug.panic("Node was already touched by consumer", .{});
                    }
                }
                if (ctx.all_producers_done()) {
                    break;
                } else {
                    Fiber.yield();
                }
            }
            ctx.consumer_done = true;
            ctx.wait_group.finish();
        }

        pub fn all_producers_done(ctx: *@This()) bool {
            for (ctx.producers_done) |done| {
                if (!done.load(.seq_cst)) {
                    return false;
                }
            }
            return true;
        }
    };
    var ctx: Ctx = .{
        .stack = .{},
        .nodes = nodes,
        .producers_done = producers_done,
        .observed_orders = observed_orders,
    };
    for (observed_orders) |*array| {
        array.* = std.ArrayList(usize).initCapacity(
            testing.allocator,
            node_per_fiber,
        ) catch unreachable;
    }
    defer {
        for (ctx.observed_orders) |*array| {
            array.*.deinit();
        }
    }
    ctx.wait_group.start();
    try Fiber.go(
        Ctx.consumer,
        .{&ctx},
        testing.allocator,
        tp.executor(),
    );
    for (0..producer_count) |i| {
        ctx.wait_group.start();
        try Fiber.goOptions(
            Ctx.producer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{ .stack_size = 1024 * 16 },
        );
    }
    ctx.wait_group.wait();
    try testing.expect(ctx.all_producers_done());
    try testing.expect(ctx.consumer_done);
    for (ctx.nodes) |node| {
        try testing.expect(node.touched_by_producer.load(.seq_cst));
        try testing.expect(node.touched_by_consumer.load(.seq_cst));
    }
    for (ctx.observed_orders, 0..) |observed_order, producer_idx| {
        const items = observed_order.items;
        for (items[0 .. items.len - 2], 0..) |a_i, i| {
            for (items[1 .. items.len - 1], 1..) |a_j, j| {
                if (j <= i) {
                    continue;
                }
                for (items[2..], 2..) |a_k, k| {
                    if (k <= j) {
                        continue;
                    }
                    if (a_i > a_k and a_k > a_j) {
                        std.debug.print(
                            "Impossible partial ordering observed in Producer #{}. {}(index:{})>{}(index:{})>{}(index:{})\n",
                            .{ producer_idx, a_i, a_k, a_j, i, k, j },
                        );
                        try testing.expect(false);
                    }
                }
            }
        }
    }
}

test "queue - basic" {
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    const Node = struct {
        intrusive_list_node: Containers.Intrusive.Node = .{},
        data: usize = 0,
    };
    const node_count = 100;
    var nodes: [node_count]Node = [_]Node{.{}} ** node_count;
    var queue: Queue(Node) = .{};
    for (&nodes, 0..) |*node, i| {
        node.*.data = i;
        queue.pushBack(node);
    }
    var i: usize = 0;
    while (queue.popFront()) |node| : (i += 1) {
        try testing.expectEqual(i, node.data);
    }
    try testing.expectEqual(node_count, i);
}

test "queue - multiple producers - manual" {
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }
    var manual_executor: ManualExecutor = .{};
    const Node = struct {
        intrusive_list_node: Containers.Intrusive.Node = .{},
        data: usize = 0,
    };
    const fiber_count = 100;
    const node_per_fiber = 100;
    const node_count = fiber_count * node_per_fiber;
    const nodes = try testing.allocator.alloc(Node, node_count);
    defer testing.allocator.free(nodes);
    for (nodes) |*node| {
        node.* = .{};
    }
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
        .nodes = nodes,
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
    if (build_config.sanitize == .thread) {
        return error.SkipZigTest;
    }

    var fiber_name_buffer: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES:0]u8 = undefined;
    const cpu_count = try std.Thread.getCpuCount();
    var tp = try ThreadPool.init(cpu_count, testing.allocator);
    defer tp.deinit();
    try tp.start();
    defer tp.stop();

    const Node = struct {
        intrusive_list_node: Containers.Intrusive.Node = .{},
        producer_idx: usize = 0,
        local_order: usize = 0,
        touched_by_producer: Atomic(bool) = .init(false),
        touched_by_consumer: Atomic(bool) = .init(false),
    };
    const producer_count = 100;
    const node_per_fiber = 100;
    const node_count = producer_count * node_per_fiber;
    const nodes = try testing.allocator.alloc(Node, node_count);
    defer testing.allocator.free(nodes);
    for (nodes) |*node| {
        node.* = .{};
    }
    const producers_done = try testing.allocator.alloc(Atomic(bool), producer_count);
    defer testing.allocator.free(producers_done);
    for (producers_done) |*done| {
        done.* = Atomic(bool).init(false);
    }
    const Ctx = struct {
        queue: Queue(Node),
        nodes: []Node,
        producers_done: []Atomic(bool),
        consumer_done: bool = false,
        wait_group: WaitGroup = .{},

        pub fn producer(ctx: *@This(), producer_idx: usize) void {
            for (0..node_per_fiber) |i| {
                const node_idx = producer_idx * node_per_fiber + i;
                const node: *Node = &ctx.nodes[node_idx];
                if (node.*.touched_by_producer.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
                    std.debug.panic(
                        "Producer #{} was about to fill in Node {}, but it was already touched by another producer",
                        .{ producer_idx, node },
                    );
                }
                node.producer_idx = producer_idx;
                node.local_order = i;
                ctx.queue.pushBack(node);
                Fiber.yield();
            }
            ctx.producers_done[producer_idx].store(true, .seq_cst);
            ctx.wait_group.finish();
        }

        pub fn consumer(ctx: *@This()) !void {
            var local_orders: [producer_count]usize = [_]usize{0} ** producer_count;
            while (true) {
                while (ctx.queue.popFront()) |node| {
                    const producer_idx = node.producer_idx;
                    try testing.expectEqual(
                        local_orders[producer_idx],
                        node.local_order,
                    );
                    local_orders[producer_idx] += 1;
                    if (node.touched_by_consumer.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
                        std.debug.panic("Consumer saw node {} twice.", .{node});
                    }
                }
                if (ctx.all_producers_done()) {
                    break;
                } else {
                    Fiber.yield();
                }
            }
            ctx.consumer_done = true;
            ctx.wait_group.finish();
        }

        pub fn all_producers_done(ctx: *@This()) bool {
            for (ctx.producers_done) |done| {
                if (!done.load(.seq_cst)) {
                    return false;
                }
            }
            return true;
        }
    };
    var ctx: Ctx = .{
        .queue = .{},
        .nodes = nodes,
        .producers_done = producers_done,
    };
    ctx.wait_group.start();
    try Fiber.goOptions(
        Ctx.consumer,
        .{&ctx},
        testing.allocator,
        tp.executor(),
        .{
            .fiber = .{ .name = "Consumer" },
        },
    );
    for (0..producer_count) |i| {
        ctx.wait_group.start();
        const name = try std.fmt.bufPrintZ(
            &fiber_name_buffer,
            "Producer #{}",
            .{i},
        );
        try Fiber.goOptions(
            Ctx.producer,
            .{ &ctx, i },
            testing.allocator,
            tp.executor(),
            .{
                .fiber = .{ .name = name },
                .stack_size = 1024 * 16,
            },
        );
    }
    ctx.wait_group.wait();
    try testing.expect(ctx.all_producers_done());
    try testing.expect(ctx.consumer_done);
    for (ctx.nodes) |node| {
        try testing.expect(node.touched_by_producer.load(.seq_cst));
        try testing.expect(node.touched_by_consumer.load(.seq_cst));
    }
}
