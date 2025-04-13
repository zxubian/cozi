const std = @import("std");

pub const threadPools = @import("./threadPools.zig");
pub const Manual = @import("./manual.zig");
pub const Executor = @import("./executor.zig");

pub const @"inline" = @import("./inline.zig").executor;

test {
    std.testing.refAllDecls(@This());
}
