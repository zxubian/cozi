test {
    _ = @import("./core/main.zig");
    _ = @import("./containers/main.zig");
    _ = @import("./coroutine/main.zig");
    _ = @import("./executors/main.zig");
    _ = @import("./fiber/main.zig");
    _ = @import("./io/tests.zig");
    _ = @import("./sync/main.zig");
    _ = @import("./future/main.zig");
}
