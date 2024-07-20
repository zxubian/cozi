const std = @import("std");
const log = std.log.scoped(.queue);
const Mutex = std.Thread.Mutex;
const CondVar = std.Thread.Condition;

pub fn UnboundedBlockingQueue(comptime T: type) type {
    const BackingQueue = std.DoublyLinkedList(T);
    return struct {
        const Impl = @This();

        backing_queue: BackingQueue = undefined,
        mutex: Mutex = .{},
        queue_empty_cond: CondVar = .{},
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Impl) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.backing_queue.pop()) |node| {
                self.allocator.destroy(node);
            }
        }

        pub fn put(self: *Impl, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var node = try self.allocator.create(BackingQueue.Node);
            node.data = value;
            self.backing_queue.append(node);
            self.queue_empty_cond.signal();
        }

        pub fn takeBlocking(self: *Impl) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.backing_queue.len == 0) {
                self.queue_empty_cond.wait(&self.mutex);
            }
            const node = self.backing_queue.popFirst().?;
            defer self.allocator.destroy(node);
            return node.data;
        }
    };
}
