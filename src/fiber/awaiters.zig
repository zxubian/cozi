const Fiber = @import("../fiber.zig");
const Awaiter = @import("./awaiter.zig");

pub const YieldAwaiter = struct {
    pub fn awaiter() Awaiter {
        return Awaiter{
            .ptr = undefined,
            .vtable = .{
                .@"await" = YieldAwaiter.@"await",
            },
        };
    }
    pub fn @"await"(_: *anyopaque, fiber: *Fiber) void {
        fiber.scheduleSelf();
    }
};
