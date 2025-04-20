const std = @import("std");

pub const BuildVariant = enum {
    none,
    thread_sleep,
    thread_yield,
    fiber,
};

pub const stdlike = @import("./stdlike/root.zig");

const fault_injection_builtin = @import("zinc_fault_injection");
const Injector = @import("./injector.zig");

var injector: Injector = if (fault_injection_builtin.build_variant == .none)
{} else .{};

pub fn injectFault() void {
    injector.maybeInjectFault();
}
