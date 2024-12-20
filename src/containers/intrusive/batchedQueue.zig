const std = @import("std");
const IntrusiveList = @import("../intrusive.zig").ForwardList;
const Queue = IntrusiveList.IntrusiveForwardList;
const SpinLock = @import("../../sync.zig").Spinlock;

pub fn BatchedQueue(T: type) type {
    return struct {
        raw: Queue(T) = .{},
        lock: SpinLock = .{},

        const Self = @This();

        pub fn takeBatch(self: *Self, dest_buffer: []*T) usize {
            const guard = self.lock.lock();
            defer guard.unlock();

            const count = self.raw.count;
            const max_batch_size = dest_buffer.len;
            const batch_size = @min(count, max_batch_size);

            for (dest_buffer[0..batch_size]) |*to| {
                to.* = self.raw.popFront().?;
            }
            return batch_size;
        }

        pub fn pushBack(
            self: *Self,
            data: *T,
        ) usize {
            const guard = self.lock.lock();
            defer guard.unlock();
            const count_before = self.raw.count;
            self.raw.pushBack(data);
            return count_before;
        }
    };
}
