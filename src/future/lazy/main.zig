const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../main.zig").executors;
const Executor = executors.Executor;
const core = @import("../../main.zig").core;
const Runnable = core.Runnable;

/// --- external re-exports ---
pub const Impl = struct {
    pub const submit = make.submit;
    pub const get = run.get;
};

// --- internal implementation ---
pub const meta = @import("./meta.zig");
pub const model = @import("./model.zig");
pub const make = @import("./make/main.zig");
pub const run = @import("./run/main.zig");

pub const State = struct {
    executor: Executor,
};

test {
    _ = @import("./tests.zig");
}
