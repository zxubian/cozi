const Coroutine = @import("../coroutine.zig");
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const alloc = std.testing.allocator;
const builtin = @import("builtin");

test "Suspend" {
    var step: usize = 0;
    var coro = Coroutine{};
    const Ctx = struct {
        pub fn run(ctx: *Coroutine, step_: *usize) void {
            step_.* += 1;
            ctx.@"suspend"();
            step_.* += 1;
        }
    };
    try coro.init(Ctx.run, .{ &coro, &step }, alloc);
    defer coro.deinit();
    try testing.expectEqual(0, step);
    try testing.expect(!coro.is_completed);
    coro.@"resume"();
    try testing.expectEqual(1, step);
    try testing.expect(!coro.is_completed);
    coro.@"resume"();
    try testing.expectEqual(2, step);
    try testing.expect(coro.is_completed);
}

test "Suspend for loop" {
    const iterations = 128;

    const Ctx = struct {
        pub fn run(ctx: *Coroutine) void {
            for (0..iterations) |_| {
                ctx.@"suspend"();
            }
        }
    };

    var coro: Coroutine = .{};
    try coro.init(Ctx.run, .{&coro}, alloc);
    defer coro.deinit();
    for (0..iterations) |_| {
        coro.@"resume"();
    }
    try testing.expect(!coro.is_completed);
    coro.@"resume"();
    try testing.expect(coro.is_completed);
}

fn expectEqual(value_name: []const u8, expected: anytype, actual: anytype) void {
    if (expected != actual) {
        std.debug.panic("unexpected value for {s}. Expected = {}. Got: {}", .{ value_name, expected, actual });
    }
}

test "Interleaving" {
    var step: usize = 0;
    const aCtx = struct {
        pub fn run(ctx: *Coroutine, step_: *usize) void {
            expectEqual("step_", 0, step_.*);
            step_.* = 1;
            ctx.@"suspend"();
            expectEqual("step_", 2, step_.*);
            step_.* = 3;
        }
    };
    const bCtx = struct {
        pub fn run(ctx: *Coroutine, step_: *usize) void {
            expectEqual("step_", 1, step_.*);
            step_.* = 2;
            ctx.@"suspend"();
            expectEqual("step_", 3, step_.*);
            step_.* = 4;
        }
    };
    var a = Coroutine{};
    var b = Coroutine{};
    try a.init(aCtx.run, .{ &a, &step }, alloc);
    try b.init(bCtx.run, .{ &b, &step }, alloc);
    defer a.deinit();
    defer b.deinit();
    a.@"resume"();
    b.@"resume"();
    try testing.expectEqual(2, step);
    a.@"resume"();
    b.@"resume"();
    try testing.expectEqual(4, step);
    try testing.expect(a.is_completed);
    try testing.expect(b.is_completed);
}

test "Threads" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var steps: usize = 0;
    const Ctx = struct {
        pub fn coroutine(
            ctx: *Coroutine,
            steps_: *usize,
        ) void {
            steps_.* += 1;
            ctx.@"suspend"();
            steps_.* += 1;
            ctx.@"suspend"();
            steps_.* += 1;
        }

        pub fn threadEntry(coro: *Coroutine) void {
            coro.@"resume"();
        }
    };
    var coro = Coroutine{};
    try coro.init(Ctx.coroutine, .{ &coro, &steps }, alloc);
    defer coro.deinit();
    for (1..4) |i| {
        var thread = try std.Thread.spawn(
            .{ .allocator = alloc },
            Ctx.threadEntry,
            .{
                &coro,
            },
        );
        thread.join();
        try testing.expectEqual(i, steps);
    }
}

const TreeNode = struct {
    left: ?*const TreeNode,
    right: ?*const TreeNode,
    data: []const u8,

    pub fn branch(
        data: []const u8,
        left: *TreeNode,
        right: *TreeNode,
        allocator: Allocator,
    ) !*TreeNode {
        const result = try allocator.create(TreeNode);
        result.* = .{
            .data = data,
            .left = left,
            .right = right,
        };
        return result;
    }

    pub fn leaf(data: []const u8, allocator: Allocator) !*TreeNode {
        const result = try allocator.create(TreeNode);
        result.* = .{
            .data = data,
            .left = null,
            .right = null,
        };
        return result;
    }
};

const TreeIterator = struct {
    walker: Coroutine = undefined,
    data: ?[]const u8 = null,

    pub fn init(
        self: *TreeIterator,
        root: *const TreeNode,
        allocator: Allocator,
    ) !void {
        try self.walker.init(
            treeWalk,
            .{
                self,
                root,
            },
            allocator,
        );
    }

    pub fn step(self: *TreeIterator) bool {
        self.walker.@"resume"();
        return !self.walker.is_completed;
    }

    fn treeWalk(
        self: *TreeIterator,
        node: *const TreeNode,
    ) void {
        if (node.left) |left| {
            self.treeWalk(left);
        }
        self.data = node.data;
        self.walker.@"suspend"();
        if (node.right) |right| {
            self.treeWalk(right);
        }
    }

    pub fn deinit(self: *TreeIterator) void {
        self.walker.deinit();
    }
};

test "Tree walk" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try TreeNode.branch(
        "B",
        try TreeNode.leaf("A", allocator),
        try TreeNode.branch(
            "F",
            try TreeNode.branch(
                "D",
                try TreeNode.leaf("C", allocator),
                try TreeNode.leaf("E", allocator),
                allocator,
            ),
            try TreeNode.leaf("G", allocator),
            allocator,
        ),
        allocator,
    );
    var iterator = TreeIterator{};
    try iterator.init(tree, alloc);
    defer iterator.deinit();
    const expected = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G" };
    var i: usize = 0;
    while (iterator.step()) : (i += 1) {
        try testing.expect(iterator.data != null);
        try testing.expectEqualStrings(expected[i], iterator.data.?);
    }
}

test "Pipeline" {
    const size: usize = 123;
    var steps: usize = 0;

    const InnerCtx = struct {
        pub fn run(ctx: *Coroutine, steps_: *usize) void {
            for (0..size) |_| {
                steps_.* += 1;
                ctx.@"suspend"();
            }
        }
    };

    const OuterCtx = struct {
        pub fn run(ctx: *Coroutine, steps_: *usize) void {
            var inner = Coroutine{};
            inner.init(InnerCtx.run, .{ &inner, steps_ }, alloc) catch unreachable;
            defer inner.deinit();
            while (!inner.is_completed) {
                inner.@"resume"();
                ctx.@"suspend"();
            }
        }
    };

    var outer = Coroutine{};
    try outer.init(OuterCtx.run, .{ &outer, &steps }, alloc);
    defer outer.deinit();

    while (!outer.is_completed) {
        outer.@"resume"();
    }

    try testing.expectEqual(size, steps);
}
