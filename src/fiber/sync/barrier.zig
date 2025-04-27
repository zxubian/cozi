//! Barrier for fibers.
//! Waiting on a Barrier does not block the underlying thread -
//! instead, the fiber is parked until the Barrier counter reaches 0.
const std = @import("std");

const cozi = @import("../../root.zig");
const Fiber = cozi.Fiber;
const WaitGroup = Fiber.WaitGroup;
const log = cozi.core.log.scoped(.fiber_barrier);

const Barrier = @This();

wait_group: WaitGroup = .{},

pub fn add(self: *Barrier, count: u32) void {
    self.wait_group.add(count);
}

pub fn join(self: *Barrier) void {
    self.wait_group.done();
    self.wait_group.wait();
}

test {
    _ = @import("./barrier/tests.zig");
}
