const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../main.zig").executors;
const Executor = executors.Executor;
const core = @import("../../main.zig").core;
const Runnable = core.Runnable;

/// --- external re-exports ---
pub const Impl = struct {
    // --- generators ---
    pub const submit = make.submit;
    pub const just = make.just;
    pub const value = make.value;
    // --- combinators ---
    pub const via = combinators.via;
    pub const map = combinators.map;
    // --- terminators ---
    pub const get = run.get;
    // --- syntax ---
    pub const pipeline = syntax.pipeline;
};

// --- internal implementation ---
pub const meta = @import("./meta.zig");
pub const model = @import("./model.zig");
pub const make = @import("./make/main.zig");
pub const run = @import("./run/main.zig");
pub const combinators = @import("./combinators/main.zig");
pub const syntax = @import("./syntax/main.zig");

pub const State = struct {
    executor: Executor,
};

test {
    _ = @import("./tests.zig");
}
