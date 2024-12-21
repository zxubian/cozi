const std = @import("std");
const Fiber = @import("../fiber.zig");
const SuspendIllegalScope = @This();

fiber: *Fiber,

pub fn Begin(this: *SuspendIllegalScope) void {
    this.fiber.suspend_illegal_scope = this;
}

pub fn End(this: *SuspendIllegalScope) void {
    this.fiber.suspend_illegal_scope = null;
    this.fiber = undefined;
}
