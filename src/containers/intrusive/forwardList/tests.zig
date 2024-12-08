const std = @import("std");
const testing = std.testing;
const alloc = testing.allocator;

const IntrusiveForwardListT = @import("../forwardList.zig");
const StackT = IntrusiveForwardListT.IntrusiveForwardList;

test "Queue - Basic" {
    const Data = struct {
        intrusive_list_node: IntrusiveForwardListT.Node,
        value: usize,
    };
    const Stack = StackT(Data);
    const test_data = try alloc.alloc(Data, 100);
    defer alloc.free(test_data);

    for (test_data, 0..) |*d, i| {
        d.value = i;
    }
    var queue = Stack{};

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
        intrusive_list_node: IntrusiveForwardListT.Node,
        value: usize,
    };
    const Stack = StackT(Data);
    const test_data = try alloc.alloc(Data, 100);
    defer alloc.free(test_data);

    for (test_data, 0..) |*d, i| {
        d.value = i;
    }
    var queue = Stack{};

    try testing.expect(queue.isEmpty());

    for (test_data) |*d| {
        queue.pushFront(d);
    }

    var i: isize = 99;
    while (queue.popFront()) |data| : (i -= 1) {
        try testing.expectEqual(@as(usize, @intCast(i)), data.value);
    }
}
