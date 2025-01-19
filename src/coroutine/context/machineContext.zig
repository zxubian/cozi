const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log.scoped(.coroutine_machine_context);

const Stack = @import("../../core/main.zig").Stack;
const Trampoline = @import("./trampoline.zig");

const MachineContext = @This();

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
        machine_context: *anyopaque,
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

    stack_pointer: *anyopaque,
    user_trampoline: Trampoline,

    pub fn init(
        self: *Aarch64Impl,
        stack: Stack,
        user_trampoline: Trampoline,
    ) void {
        const stack_top = stack.top();
        log.debug(
            "storing machineContext impl ptr to stack: 0x{x:0>8}",
            .{@intFromPtr(self)},
        );
        self.stack_pointer = machine_context_init(
            @ptrCast(stack_top),
            runTrampoline,
            self,
        );
        assert(@intFromPtr(stack.base()) <= @intFromPtr(self.stack_pointer));
        assert(@intFromPtr(self.stack_pointer) < @intFromPtr(stack.top()));
        self.user_trampoline = user_trampoline;
    }

    pub fn switchTo(self: *Aarch64Impl, other: *Aarch64Impl) void {
        machine_context_switch_to(&self.stack_pointer, &other.stack_pointer);
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
        log.debug(
            "recovered machineContext impl ptr from stack: 0x{x:0>8}",
            .{@intFromPtr(ctx)},
        );
        const self: *Aarch64Impl = @ptrCast(@alignCast(ctx));
        self.user_trampoline.run();
    }

    test "Machine Context - Validate Stack" {
        const allocator = std.testing.allocator;
        const stack_managed = try Stack.Managed.init(allocator);
        defer stack_managed.deinit();
        var machine_ctx: Aarch64Impl = undefined;
        machine_ctx.init(stack_managed.raw, undefined);
        const validateStack = struct {
            fn validateStack(
                stack: Stack,
                machine_ctx_ptr: *anyopaque,
                trampoline_fn: TrampolineProto,
            ) !void {
                const slice = stack.slice;
                const Ctx = struct {
                    i: usize,
                    slice: []u8,
                    stack: Stack,
                    pub fn validateRange(
                        self: *@This(),
                        len: usize,
                        expected: anytype,
                    ) !void {
                        const byte_size = @sizeOf(@TypeOf(expected));
                        var count: usize = 0;
                        while (count < len) : (count += 1) {
                            self.i -= byte_size;
                            const value = std.mem.bytesToValue(
                                @TypeOf(expected),
                                self.slice[self.i .. self.i + byte_size],
                            );
                            try std.testing.expectEqual(expected, value);
                        }
                    }
                };
                var ctx: Ctx = .{
                    .slice = slice,
                    .i = slice.len,
                    .stack = stack,
                };

                const empty_byte_count: usize = 64 + 8;
                const empty_byte_value: u8 = 0xAA;
                try ctx.validateRange(empty_byte_count, @as(u8, empty_byte_value));

                try ctx.validateRange(1, @intFromPtr(machine_ctx_ptr));

                try ctx.validateRange(1, @as(usize, 0));

                try ctx.validateRange(1, @intFromPtr(trampoline_fn));

                const general_purpose_register_count: usize = 5 * 2;
                try ctx.validateRange(general_purpose_register_count, @as(u64, 0));

                const floating_point_register_count: usize = 12 * 2;
                try ctx.validateRange(floating_point_register_count, @as(f64, 0));
            }
        }.validateStack;

        try validateStack(
            stack_managed.raw,
            &machine_ctx,
            runTrampoline,
        );
    }

    test "Machine Context - Validate Stack Pointer" {
        const allocator = std.testing.allocator;
        const stack_managed = try Stack.Managed.init(allocator);
        defer stack_managed.deinit();
        var machine_ctx: Aarch64Impl = undefined;
        machine_ctx.init(stack_managed.raw, undefined);
        const validateStackPointer = struct {
            fn validateStackPointer(
                stack_pointer: *anyopaque,
                machine_ctx_ptr: *anyopaque,
                trampoline_fn: TrampolineProto,
            ) !void {
                const Ctx = struct {
                    stack_pointer: *anyopaque,
                    pub fn validateRange(
                        self: *@This(),
                        len: usize,
                        expected: anytype,
                    ) !void {
                        const byte_size = @sizeOf(@TypeOf(expected));
                        var count: usize = 0;
                        while (count < len) : ({
                            count += 1;

                            self.stack_pointer = @ptrFromInt(@intFromPtr(self.stack_pointer) + byte_size);
                        }) {
                            const value_ptr: *@TypeOf(expected) = @alignCast(@ptrCast(self.stack_pointer));
                            if (value_ptr.* != expected) {
                                std.debug.panic(
                                    "expected @0x{X:0>8}: {x} got: {x}",
                                    .{ @intFromPtr(value_ptr), expected, value_ptr.* },
                                );
                            }
                        }
                    }
                };
                var ctx: Ctx = .{ .stack_pointer = stack_pointer };

                const floating_point_register_count: usize = 12 * 2;
                try ctx.validateRange(floating_point_register_count, @as(f64, 0));

                const general_purpose_register_count: usize = 5 * 2;
                try ctx.validateRange(general_purpose_register_count, @as(u64, 0));

                try ctx.validateRange(1, @intFromPtr(trampoline_fn));

                try ctx.validateRange(1, @as(u64, 0));

                try ctx.validateRange(1, @intFromPtr(machine_ctx_ptr));

                const empty_byte_count: usize = 64 + 8;
                try ctx.validateRange(empty_byte_count, @as(u8, 0xAA));
            }
        }.validateStackPointer;
        try validateStackPointer(
            machine_ctx.stack_pointer,
            &machine_ctx,
            runTrampoline,
        );
    }
};

pub fn init(self: *MachineContext, stack: Stack, trampoline: Trampoline) void {
    self.impl.init(stack, trampoline);
}

pub fn switchTo(self: *MachineContext, other: *MachineContext) void {
    self.impl.switchTo(&other.impl);
}

test {
    _ = Impl;
}
