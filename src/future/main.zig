const lazy_ = @import("./lazy/main.zig");

pub const lazy = lazy_.Impl;

test {
    _ = lazy_;
}
