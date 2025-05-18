const std = @import("std");

// Executor interface
pub const Executor = @import("./executor.zig");

// Concrete implementations
pub const threadPools = @import("./threadPools.zig");
pub const Manual = @import("./manual.zig");
pub const @"inline" = @import("./inline.zig").executor;
pub const FiberPool = @import("./fiberPool.zig");

test {
    std.testing.refAllDecls(@This());
}
