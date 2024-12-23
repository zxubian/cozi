const std = @import("std");
const testing = std.testing;
const alloc = testing.allocator;

const Containers = @import("../../../containers.zig");
const List = Containers.Intrusive.ForwardList;
const Node = Containers.Intrusive.Node;

test "Queue - Basic" {
    const Data = struct {
        intrusive_list_node: Node,
        value: usize,
    };
    const Queue = List(Data);
    const test_data = try alloc.alloc(Data, 100);
    defer alloc.free(test_data);

    for (test_data, 0..) |*d, i| {
        d.value = i;
    }
    var queue = Queue{};

    try testing.expect(queue.isEmpty());

    for (test_data) |*d| {
        queue.pushBack(d);
    }

    var i: usize = 0;
    while (queue.popFront()) |data| : (i += 1) {
        try testing.expectEqual(i, data.value);
    }
}

test "Stack - Basic" {
    const Data = struct {
        intrusive_list_node: Containers.Intrusive.Node,
        value: usize,
    };
    const Stack = List(Data);
    const test_data = try alloc.alloc(Data, 100);
    defer alloc.free(test_data);

    for (test_data, 0..) |*d, i| {
        d.value = i;
    }
    var stack = Stack{};

    try testing.expect(stack.isEmpty());

    for (test_data) |*d| {
        stack.pushFront(d);
    }

    var i: isize = 99;
    while (stack.popFront()) |data| : (i -= 1) {
        try testing.expectEqual(@as(usize, @intCast(i)), data.value);
    }
}
