const lazy_ = @import("./lazy/root.zig");

pub const lazy = lazy_.Impl;

test {
    _ = lazy_;
}
