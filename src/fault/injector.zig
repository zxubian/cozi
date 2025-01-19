const std = @import("std");
const Injector = @This();
const fault_injection_builtin = @import("zig_async_fault_injection");
const Fiber = @import("../fiber/main.zig");

const inject_frequency = 16;
const sleep_time_ns = 100;

const uninited_state = std.math.maxInt(usize);
state: std.atomic.Value(usize) = .init(uninited_state),

pub fn maybeInjectFault(self: *Injector) void {
    if (self.state.fetchAdd(1, .seq_cst) % inject_frequency == 0) {
        injectFault();
    }
}

inline fn maybeInit(self: *Injector) void {
    _ = self.state.cmpxchgStrong(
        uninited_state,
        std.testing.random_seed,
        .seq_cst,
        .seq_cst,
    );
}

pub fn injectFault() void {
    Impl.yield();
}

const Impl = switch (fault_injection_builtin.build_variant) {
    .none => {},
    .thread => ThreadImpl,
    .fiber => FiberImpl,
};

const ThreadImpl = struct {
    pub fn yield() void {
        std.atomic.spinLoopHint();
    }

    pub fn sleep(time_ns: usize) void {
        std.Thread.sleep(time_ns);
    }
};

const FiberImpl = struct {
    pub fn yield() void {
        Fiber.yield();
    }

    pub fn sleep(_: usize) void {
        @compileError("TODO");
    }
};
