const std = @import("std");
const log = cozi.core.log.scoped(.execution_context);
const MachineContext = @import("./context/machineContext.zig");
const SanitizerContext = @import("./context/sanitizerContext.zig");
const cozi = @import("../root.zig");
const build_options = cozi.build_options.options;

const Core = @import("../core/root.zig");
const Stack = Core.Stack;
pub const Trampoline = @import("./context/trampoline.zig");

const ExecutionContext = @This();

machine_context: MachineContext = undefined,
user_trampoline: Trampoline = undefined,
sanitizer_context: SanitizerContext = .{},

pub fn init(
    self: *ExecutionContext,
    stack: Stack,
    user_trampoline: Trampoline,
) void {
    const context_trampoline = self.trampoline();
    self.user_trampoline = user_trampoline;
    self.machine_context.init(stack, context_trampoline);
    self.sanitizer_context.init(stack);
}

pub fn switchTo(self: *ExecutionContext, other: *ExecutionContext) void {
    self.sanitizer_context.beforeSwitch(&other.sanitizer_context);
    self.machine_context.switchTo(&other.machine_context);
    self.sanitizer_context.afterSwitch();
}

pub fn exitTo(self: *ExecutionContext, other: *ExecutionContext) noreturn {
    if (build_options.sanitizer_variant != .none) {
        self.sanitizer_context.beforeExit(&other.sanitizer_context);
    }
    self.machine_context.switchTo(&other.machine_context);
    unreachable;
}

fn trampoline(self: *ExecutionContext) Trampoline {
    return Trampoline{
        .ptr = self,
        .vtable = &.{
            .run = &ExecutionContext.runTrampoline,
        },
    };
}

fn runTrampoline(ctx: *anyopaque) noreturn {
    const self: *ExecutionContext = @ptrCast(@alignCast(ctx));
    self.sanitizer_context.afterStart();
    self.user_trampoline.run();
}
