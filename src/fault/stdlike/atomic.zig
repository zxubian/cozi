const std = @import("std");
const fault_injection_builtin = @import("cozi_fault_injection");
const injectFault = @import("../root.zig").injectFault;
const AtomicOrder = std.builtin.AtomicOrder;

pub fn Value(comptime T: type) type {
    return comptime switch (fault_injection_builtin.build_variant) {
        .none => std.atomic.Value(T),
        else => FaultyAtomic(T),
    };
}

fn FaultyAtomic(comptime T: type) type {
    return struct {
        raw: std.atomic.Value(T),
        const Self = @This();

        pub inline fn init(value: T) Self {
            return .{ .raw = .init(value) };
        }

        pub const fence = @compileError("@fence is deprecated, use other atomics to establish ordering");

        pub inline fn load(self: *const Self, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.load(order);
        }

        pub inline fn store(self: *Self, value: T, comptime order: AtomicOrder) void {
            injectFault();
            return self.raw.store(value, order);
        }

        pub inline fn swap(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.swap(operand, order);
        }

        pub inline fn cmpxchgWeak(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: AtomicOrder,
            comptime fail_order: AtomicOrder,
        ) ?T {
            injectFault();
            return self.raw.cmpxchgWeak(expected_value, new_value, success_order, fail_order);
        }

        pub inline fn cmpxchgStrong(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: AtomicOrder,
            comptime fail_order: AtomicOrder,
        ) ?T {
            injectFault();
            return self.raw.cmpxchgStrong(expected_value, new_value, success_order, fail_order);
        }

        pub inline fn fetchAdd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchAdd(operand, order);
        }

        pub inline fn fetchSub(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchSub(operand, order);
        }

        pub inline fn fetchMin(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchMin(operand, order);
        }

        pub inline fn fetchMax(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchMax(operand, order);
        }

        pub inline fn fetchAnd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchAnd(operand, order);
        }

        pub inline fn fetchNand(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchNand(operand, order);
        }

        pub inline fn fetchXor(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchXor(operand, order);
        }

        pub inline fn fetchOr(self: *Self, operand: T, comptime order: AtomicOrder) T {
            injectFault();
            return self.raw.fetchOr(operand, order);
        }

        pub inline fn rmw(
            self: *Self,
            comptime op: std.builtin.AtomicRmwOp,
            operand: T,
            comptime order: AtomicOrder,
        ) T {
            injectFault();
            return self.raw.rmw(op, operand, order);
        }

        const Bit = std.math.Log2Int(T);

        /// Marked `inline` so that if `bit` is comptime-known, the instruction
        /// can be lowered to a more efficient machine code instruction if
        /// possible.
        pub inline fn bitSet(self: *Self, bit: Bit, comptime order: AtomicOrder) u1 {
            const mask = @as(T, 1) << bit;
            const value = self.fetchOr(mask, order);
            return @intFromBool(value & mask != 0);
        }

        /// Marked `inline` so that if `bit` is comptime-known, the instruction
        /// can be lowered to a more efficient machine code instruction if
        /// possible.
        pub inline fn bitReset(self: *Self, bit: Bit, comptime order: AtomicOrder) u1 {
            const mask = @as(T, 1) << bit;
            const value = self.fetchAnd(~mask, order);
            return @intFromBool(value & mask != 0);
        }

        /// Marked `inline` so that if `bit` is comptime-known, the instruction
        /// can be lowered to a more efficient machine code instruction if
        /// possible.
        pub inline fn bitToggle(self: *Self, bit: Bit, comptime order: AtomicOrder) u1 {
            const mask = @as(T, 1) << bit;
            const value = self.fetchXor(mask, order);
            return @intFromBool(value & mask != 0);
        }
    };
}
