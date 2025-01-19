const builtin = @import("builtin");
const build_config = @import("build_config");
const ThreadSanitizerContext = @import("./sanitizer/threadSanitizerContext.zig");
const AddressSanitizerContext = @import("./sanitizer/AddressSanitizerContext.zig");
const Stack = @import("../../core/main.zig").Stack;

pub const Context = @This();

impl: Impl = .{},

const Impl = switch (build_config.sanitize) {
    .none => NoopContext,
    .address => AddressSanitizerContext,
    .thread => ThreadSanitizerContext,
};

const NoopContext = struct {
    pub fn init(_: *NoopContext, _: Stack) void {}
    pub fn afterStart(_: *NoopContext) void {}
    pub fn beforeSwitch(_: *NoopContext, _: *NoopContext) void {}
    pub fn afterSwitch(_: *NoopContext) void {}
    pub fn beforeExit(_: *NoopContext, _: *NoopContext) void {}
};

pub fn init(self: *Context, stack: Stack) void {
    if (@TypeOf(self.impl) != void) {
        self.impl.init(stack);
    }
}

pub fn afterStart(self: *Context) void {
    if (@TypeOf(self.impl) != void) {
        self.impl.afterStart();
    }
}

pub fn beforeSwitch(self: *Context, other: *Context) void {
    if (@TypeOf(self.impl) != void) {
        self.impl.beforeSwitch(&other.impl);
    }
}

pub fn afterSwitch(self: *Context) void {
    if (@TypeOf(self.impl) != void) {
        self.impl.afterSwitch();
    }
}

pub fn beforeExit(self: *Context, other: *Context) void {
    if (@TypeOf(self.impl) != void) {
        self.impl.beforeExit(&other.impl);
    }
}
