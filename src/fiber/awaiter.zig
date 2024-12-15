const std = @import("std");
const Fiber = @import("../fiber.zig");
const Awaiter = @This();

ptr: *anyopaque,
vtable: struct {
    @"await": *const fn (ctx: *anyopaque, fiber: *Fiber) void,
},

pub inline fn @"await"(self: *Awaiter, fiber: *Fiber) void {
    self.vtable.@"await"(self.ptr, fiber);
}
