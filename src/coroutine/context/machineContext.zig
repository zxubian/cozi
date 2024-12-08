const MachineContext = @This();
const Stack = @import("../../stack.zig");
const Trampoline = @import("./trampoline.zig");
const builtin = @import("builtin");
const std = @import("std");

impl: Impl,

const Impl = blk: {
    break :blk switch (builtin.target.cpu.arch) {
        .aarch64 => Aarch64Impl,
        else => @compileError(
            std.fmt.comptimePrint(
                "{s} is not imlemented for target architecture {s}",
                .{
                    @typeName(@This()),
                    @tagName(builtin.target.cpu.arch),
                },
            ),
        ),
    };
};

const Aarch64Impl = struct {
    const TrampolineProto = *const fn (
        *anyopaque,
        *anyopaque,
        *anyopaque,
        *anyopaque,
        *anyopaque,
        *anyopaque,
        *anyopaque,
        *anyopaque,
        *anyopaque,
    ) callconv(.C) void;

    extern fn machine_context_init(
        stack: ?[*]u8,
        trampoline_run: TrampolineProto,
        trampoline_ctx: *anyopaque,
    ) callconv(.C) *anyopaque;

    extern fn machine_context_switch_to(
        old_stack_pointer: **anyopaque,
        new_stack_pointer: **anyopaque,
    ) callconv(.C) void;

    /// stack pointer
    rsp: *anyopaque,
    user_trampoline: Trampoline,

    pub fn init(self: *Aarch64Impl, stack: Stack, user_trampoline: Trampoline) void {
        const stack_bottom = stack.bottom();
        self.rsp = machine_context_init(
            @ptrCast(stack_bottom),
            runTrampoline,
            self,
        );
        const used_stack_space_bytes = @intFromPtr(stack_bottom) - @intFromPtr(self.rsp);
        std.debug.assert(used_stack_space_bytes == 336);
        self.user_trampoline = user_trampoline;
    }

    pub fn switchTo(self: *Aarch64Impl, other: *Aarch64Impl) void {
        machine_context_switch_to(&self.rsp, &other.rsp);
    }

    /// We want to pass ctx on the stack, so we will use the 9th argument
    fn runTrampoline(
        _: *anyopaque,
        _: *anyopaque,
        _: *anyopaque,
        _: *anyopaque,
        _: *anyopaque,
        _: *anyopaque,
        _: *anyopaque,
        _: *anyopaque,
        ctx: *anyopaque,
    ) callconv(.C) void {
        const self: *Aarch64Impl = @ptrCast(@alignCast(ctx));
        self.user_trampoline.run();
    }
};

pub fn init(self: *MachineContext, stack: Stack, trampoline: Trampoline) void {
    self.impl.init(stack, trampoline);
}

pub fn switchTo(self: *MachineContext, other: *MachineContext) void {
    self.impl.switchTo(&other.impl);
}
