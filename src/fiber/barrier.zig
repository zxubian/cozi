//! Barrier for fibers.
//! Waiting on a Barrier does not block the underlying thread -
//! instead, the fiber is parked until the Barrier counter reaches 0.
const std = @import("std");
const Barrier = @This();

const WaitGroup = @import("./wait_group.zig");

const Fiber = @import("../fiber.zig");

const log = std.log.scoped(.fiber_barrier);

wait_group: WaitGroup = .{},

pub fn add(self: *Barrier, count: isize) void {
    self.wait_group.add(count);
}

pub fn join(self: *Barrier) void {
    self.wait_group.done();
    self.wait_group.wait();
}

test {
    _ = @import("./barrier/tests.zig");
}
