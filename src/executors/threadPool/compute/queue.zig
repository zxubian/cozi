const std = @import("std");
const assert = std.debug.assert;
const Mutex = std.Thread.Mutex;
const CondVar = std.Thread.Condition;

const cozi = @import("../../../root.zig");
const Queue = cozi.containers.intrusive.ForwardList;
const log = cozi.core.log.scoped(.queue);

pub fn UnboundedBlockingQueue(comptime T: type) type {
    const BackingQueue = Queue(T);
    return struct {
        const Impl = @This();

        backing_queue: BackingQueue = undefined,
        mutex: Mutex = .{},
        has_entries_or_is_closed: CondVar = .{},
        closed: bool = false,

        pub fn deinit(self: *Impl) void {
            self.backing_queue.reset();
        }

        const QueueError = error{
            queue_closed,
        };

        pub fn put(self: *Impl, value: *T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) {
                return QueueError.queue_closed;
            }
            self.backing_queue.pushBack(value);
            self.has_entries_or_is_closed.signal();
        }

        pub fn takeBlocking(self: *Impl) !*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.backing_queue.count == 0 and !self.closed) {
                self.has_entries_or_is_closed.wait(&self.mutex);
            }
            if (self.backing_queue.popFront()) |t| {
                return t;
            }
            assert(self.closed);
            return QueueError.queue_closed;
        }

        pub fn close(self: *Impl) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.has_entries_or_is_closed.broadcast();
        }
    };
}
