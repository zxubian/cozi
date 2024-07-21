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
        has_entries_or_is_closed: CondVar = .{},
        allocator: std.mem.Allocator,
        closed: bool = false,

        pub fn deinit(self: *Impl) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.backing_queue.pop()) |node| {
                self.allocator.destroy(node);
            }
        }

        const PutError = error{
            queue_closed,
        };

        pub fn put(self: *Impl, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) {
                return PutError.queue_closed;
            }
            var node = try self.allocator.create(BackingQueue.Node);
            node.data = value;
            self.backing_queue.append(node);
            self.has_entries_or_is_closed.signal();
        }

        pub fn takeBlocking(self: *Impl) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.backing_queue.len == 0 and !self.closed) {
                self.has_entries_or_is_closed.wait(&self.mutex);
            }
            if (self.closed) {
                return null;
            }
            const node = self.backing_queue.popFirst().?;
            defer self.allocator.destroy(node);
            return node.data;
        }

        pub fn close(self: *Impl) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.has_entries_or_is_closed.signal();
        }
    };
}
