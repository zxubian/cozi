pub const ThreadPools = @import("./executors/threadPools.zig");
pub const Manual = @import("./executors/manual.zig");

test {
    _ = @import("./executors/threadPools.zig");
    _ = @import("./executors/manual.zig");
}
