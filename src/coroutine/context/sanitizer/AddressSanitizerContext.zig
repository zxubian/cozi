const builtin = @import("builtin");
const AddressSanitizerContext = @This();
const Core = @import("../../../core/main.zig");
const Stack = Core.Stack;

stack: Stack = undefined,
fake_stack: *anyopaque = undefined,
previous_context: ?*AddressSanitizerContext = null,

const asan = struct {
    extern "c" fn __sanitizer_start_switch_fiber(
        fake_stack_save: ?**anyopaque,
        bottom: *const anyopaque,
        size: usize,
    ) void;
    extern "c" fn __sanitizer_finish_switch_fiber(
        fake_stack_save: ?**anyopaque,
        bottom_old: *const anyopaque,
        size_old: usize,
    ) void;
};

pub fn init(self: *AddressSanitizerContext, stack: Stack) void {
    self.stack = stack;
}

pub fn afterStart(self: *AddressSanitizerContext) void {
    asan.__sanitizer_finish_switch_fiber(
        null,
        self.previous_context.stack.bottom(),
        self.previous_context.stack.len,
    );
}

pub fn beforeSwitch(self: *AddressSanitizerContext, other: *AddressSanitizerContext) void {
    other.previous_context = self;
    asan.__sanitizer_start_switch_fiber(
        &self.fake_stack,
        other.stack.bottom(),
        other.stack.len,
    );
}

pub fn afterSwitch(self: *AddressSanitizerContext) void {
    asan.__sanitizer_finish_switch_fiber(
        &self.fake_stack,
        self.previous_context.stack.bottom(),
        self.previous_context.stack.len,
    );
}

pub fn beforeExit(self: *AddressSanitizerContext, other: *AddressSanitizerContext) void {
    other.previous_context = self;
    asan.__sanitizer_start_switch_fiber(
        null,
        other.stack.bottom(),
        other.stack.len,
    );
}
