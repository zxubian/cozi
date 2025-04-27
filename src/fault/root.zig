const std = @import("std");

pub const stdlike = @import("./stdlike/root.zig");

const cozi = @import("../root.zig");
const Injector = @import("./injector.zig");
const build_options = cozi.build_options;
const fault_variant = build_options.fault.variant;

var injector: Injector =
    switch (fault_variant) {
        .none => {},
        else => .{},
    };

pub fn injectFault() void {
    if (fault_variant == .none) {
        return;
    }
    injector.maybeInjectFault();
}
