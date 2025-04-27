const std = @import("std");

const cozi = @import("../root.zig");
const Fiber = cozi.Fiber;
const build_options = cozi.build_options;
const fault_variant = build_options.fault.variant;

const Injector = @This();

const inject_frequency = 9;
const sleep_time_ns = 1000;

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
    switch (fault_variant) {
        .none => {},
        .thread_yield, .fiber => Impl.yield(),
        .thread_sleep => Impl.sleep(sleep_time_ns),
    }
}

const Impl = switch (fault_variant) {
    .none => {},
    .thread_yield, .thread_sleep => ThreadImpl,
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
