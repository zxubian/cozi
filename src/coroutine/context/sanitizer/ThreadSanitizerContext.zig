const std = @import("std");
const builtin = @import("builtin");
const Core = @import("../../../core/main.zig");
const Stack = Core.Stack;

const ThreadSanitizerContext = @This();

const tsan = struct {
    extern "c" fn __tsan_create_fiber(flags: c_uint) *anyopaque;
    extern "c" fn __tsan_get_current_fiber() *anyopaque;
    extern "c" fn __tsan_destroy_fiber(fiber: *anyopaque) void;
    extern "c" fn __tsan_switch_to_fiber(fiber: ?*anyopaque, flags: c_uint) void;
    extern "c" fn __tsan_set_fiber_name(fiber: ?*anyopaque, name: [*:0]const u8) void;
};

fiber: ?*anyopaque = null,
exited_from: ?*ThreadSanitizerContext = null,

pub fn init(self: *ThreadSanitizerContext, _: Stack) void {
    self.fiber = tsan.__tsan_create_fiber(0);
    var buf: [256]u8 = std.mem.zeroes([256]u8);
    const formatted = std.fmt.bufPrint(&buf, "Fiber from ThreadSanitizerContext @{*}", .{self}) catch unreachable;
    tsan.__tsan_set_fiber_name(self.fiber, @ptrCast(formatted.ptr));
}

pub fn afterStart(self: *ThreadSanitizerContext) void {
    self.maybeCleanUpAfterExit();
}

pub inline fn beforeSwitch(self: *ThreadSanitizerContext, other: *ThreadSanitizerContext) void {
    self.fiber = tsan.__tsan_get_current_fiber();
    tsan.__tsan_switch_to_fiber(other.fiber, 0);
}

pub inline fn afterSwitch(self: *ThreadSanitizerContext) void {
    self.maybeCleanUpAfterExit();
}

pub inline fn beforeExit(self: *ThreadSanitizerContext, other: *ThreadSanitizerContext) void {
    other.setExitedFrom(self);
    tsan.__tsan_switch_to_fiber(other.fiber, 0);
}

fn setExitedFrom(self: *ThreadSanitizerContext, other: *ThreadSanitizerContext) void {
    self.exited_from = other;
}

fn maybeCleanUpAfterExit(self: *ThreadSanitizerContext) void {
    if (self.exited_from) |other_context| {
        tsan.__tsan_destroy_fiber(other_context.*.fiber.?);
        other_context.*.fiber = null;
    }
}
