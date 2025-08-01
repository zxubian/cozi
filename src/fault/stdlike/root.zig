const std = @import("std");
const cozi = @import("../../root.zig");

pub const atomic = @import("./atomic.zig");

pub const Futex = struct {
    pub fn wait(value: *atomic.Value(u32), expect: u32) void {
        switch (cozi.build_options.options.fault_variant) {
            .none => {
                std.Thread.Futex.wait(value, expect);
            },
            else => {
                std.Thread.Futex.wait(&value.raw, expect);
            },
        }
    }

    pub fn wake(value: *const atomic.Value(u32), max_waiters: u32) void {
        switch (cozi.build_options.options.fault_variant) {
            .none => {
                std.Thread.Futex.wake(value, max_waiters);
            },
            else => {
                std.Thread.Futex.wake(&value.raw, max_waiters);
            },
        }
    }
};
