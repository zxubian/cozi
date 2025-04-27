const std = @import("std");
const DeadlockDetector = @This();
const Thread = std.Thread;
const ThreadExt = @import("../thread.zig");
const assert = std.debug.assert;
const log = cozi.core.log.scoped(.deadlock_detector);

var mutex_: Thread.Mutex = .{};
var gpa_: std.heap.GeneralPurposeAllocator(.{}) = .{};
const allocator = gpa_.allocator();
var owner_per_resource_: std.AutoHashMap(*anyopaque, *OwnerList) = .init(allocator);
var wait_for_graph_: WaitForGraph = .init(allocator);

const OwnerList = std.DoublyLinkedList(*Thread);

const WaitForGraph = struct {
    adjacency_list: std.AutoHashMap(*Thread, WaitForDependency),
    pub const WaitForDependency = struct { resource: *anyopaque, owner: *Thread };

    pub fn init(gpa: std.mem.Allocator) WaitForGraph {
        const list: std.AutoHashMap(*Thread, WaitForDependency) = std.AutoHashMap(*Thread, WaitForDependency).init(gpa);
        return .{
            .adjacency_list = list,
        };
    }

    pub fn add(
        self: *@This(),
        from: *Thread,
        to: *Thread,
        resource: *anyopaque,
    ) void {
        self.adjacency_list.putNoClobber(from, .{
            .owner = to,
            .resource = resource,
        }) catch unreachable;
    }

    pub fn remove(self: *@This(), from: *Thread) void {
        if (self.adjacency_list.fetchRemove(from)) |_| {} else unreachable;
    }

    pub fn validate(self: *@This(), start: *Thread) void {
        var current_key: *Thread = start;
        var seen: std.ArrayList(*Thread) = .init(allocator);
        defer seen.deinit();
        while (true) {
            if (std.mem.indexOfScalar(*Thread, seen.items, current_key) != null) {
                self.panic(seen.items);
            }
            seen.append(current_key) catch unreachable;
            if (self.adjacency_list.get(current_key)) |next| {
                current_key = next.owner;
            } else break;
        }
    }

    fn panic(self: *@This(), seen: []*Thread) void {
        const max_length_bytes = 2048;
        var message_buf: [max_length_bytes:0]u8 = undefined;
        var thread_name_buf: [Thread.max_name_len:0]u8 = undefined;
        var stream = std.io.fixedBufferStream(&message_buf);
        var writer = stream.writer();
        const start_thread = seen[0];
        const start_thread_name = ThreadExt.nameOrHandle(
            start_thread,
            &thread_name_buf,
        ) catch unreachable;
        writer.print("[{s}]", .{start_thread_name}) catch unreachable;
        for (seen) |thread| {
            const dependency = self.adjacency_list.get(thread).?;
            const thread_name = ThreadExt.nameOrHandle(
                dependency.owner,
                &thread_name_buf,
            ) catch unreachable;
            writer.print("-> ({*}) -> [{s}]", .{
                dependency.resource,
                thread_name,
            }) catch unreachable;
        }
        std.debug.panic("Deadlock detected! Wait-for graph:\n{s}", .{message_buf[0..stream.pos]});
    }
};

pub inline fn beforeLock(lock: *anyopaque) void {
    mutex_.lock();
    defer mutex_.unlock();
    if (ThreadExt.getCurrentThread()) |this_thread| {
        var thread_name_buf: [Thread.max_name_len:0]u8 = undefined;
        const name = ThreadExt.nameOrHandle(this_thread, &thread_name_buf) catch unreachable;
        log.debug("Thread {s} attempting to acquire lock {*}", .{ name, lock });
        const node: *OwnerList.Node = allocator.create(OwnerList.Node) catch unreachable;
        node.* = .{ .data = this_thread };
        const get_or_put = owner_per_resource_.getOrPut(lock) catch unreachable;
        if (!get_or_put.found_existing) {
            const new_list: *OwnerList = allocator.create(OwnerList) catch unreachable;
            new_list.* = .{};
            get_or_put.value_ptr.* = new_list;
        }
        const owners_list = get_or_put.value_ptr.*;
        owners_list.append(node);
        if (node.prev) |previous| {
            const owner = owners_list.first.?.data;
            var owner_name_buf: [Thread.max_name_len:0]u8 = undefined;
            const owner_name = ThreadExt.nameOrHandle(owner, &owner_name_buf) catch unreachable;
            log.debug("Lock {*} is currently owned by {s}. Adding Thread {s} to wait-for graph.", .{
                lock,
                owner_name,
                name,
            });
            wait_for_graph_.add(this_thread, previous.data, lock);
            wait_for_graph_.validate(this_thread);
        }
    }
}

pub inline fn afterUnlock(lock: *anyopaque) void {
    mutex_.lock();
    defer mutex_.unlock();
    if (ThreadExt.getCurrentThread()) |this_thread| {
        var thread_name_buf: [Thread.max_name_len:0]u8 = undefined;
        const name = ThreadExt.nameOrHandle(this_thread, &thread_name_buf) catch unreachable;
        log.debug("Thread {s} releasing lock {*}", .{ name, lock });
        const owners_list = owner_per_resource_.get(lock).?;
        const node = owners_list.popFirst().?;
        defer allocator.destroy(node);
        assert(node.data == this_thread);
        if (owners_list.len == 0) {
            allocator.destroy(owners_list);
            _ = owner_per_resource_.remove(lock);
            return;
        }
        const next_thread = node.next.?.data;
        const next_thread_name = ThreadExt.nameOrHandle(next_thread, &thread_name_buf) catch unreachable;
        wait_for_graph_.remove(next_thread);
        log.debug("{s} will be new owner of lock {*}", .{ next_thread_name, lock });
    } else unreachable;
}
