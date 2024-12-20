const std = @import("std");
const Atomic = std.atomic.Value;
const AtomicEnum = @This();
const AtomicOrder = std.builtin.AtomicOrder;

pub fn Value(comptime T: type) type {
    const type_info = @typeInfo(T);

    if (type_info != .@"enum") {
        @compileLog(type_info);
        @compileError("Must be enum");
    }

    const tag_type = type_info.@"enum".tag_type;
    if (@typeInfo(tag_type) != .int) {
        @compileError("Enum must be backed by int.");
    }

    return struct {
        raw: Atomic(BackingType),

        const Self = @This();
        const BackingType = tag_type;

        inline fn intFromEnum(enum_value: T) BackingType {
            return @as(BackingType, @intFromEnum(enum_value));
        }

        inline fn optionalEnumFromInt(int_value: ?BackingType) ?T {
            if (int_value) |v| {
                return enumFromInt(v);
            }
            return null;
        }

        inline fn enumFromInt(int_value: BackingType) T {
            return @as(T, @enumFromInt(int_value));
        }

        pub inline fn init(enum_value: T) Self {
            return Self{
                .raw = .init(intFromEnum(enum_value)),
            };
        }

        pub inline fn load(self: *const Self, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.load(order));
        }

        pub inline fn store(self: *Self, value: T, comptime order: AtomicOrder) void {
            self.raw.store(intFromEnum(value), order);
        }

        pub inline fn swap(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.swap(intFromEnum(operand), order));
        }

        pub inline fn cmpxchgWeak(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: AtomicOrder,
            comptime fail_order: AtomicOrder,
        ) ?T {
            return optionalEnumFromInt(self.raw.cmpxchgWeak(
                intFromEnum(expected_value),
                intFromEnum(new_value),
                success_order,
                fail_order,
            ));
        }

        pub inline fn cmpxchgStrong(
            self: *Self,
            expected_value: T,
            new_value: T,
            comptime success_order: AtomicOrder,
            comptime fail_order: AtomicOrder,
        ) ?T {
            return optionalEnumFromInt(self.raw.cmpxchgStrong(
                intFromEnum(expected_value),
                intFromEnum(new_value),
                success_order,
                fail_order,
            ));
        }

        pub inline fn fetchAdd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchAdd(intFromEnum(operand), order));
        }

        pub inline fn fetchSub(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchSub(intFromEnum(operand), order));
        }

        pub inline fn fetchMin(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchMin(intFromEnum(operand), order));
        }

        pub inline fn fetchMax(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchMax(intFromEnum(operand), order));
        }

        pub inline fn fetchAnd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchAnd(intFromEnum(operand), order));
        }

        pub inline fn fetchNand(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchNand(intFromEnum(operand), order));
        }

        pub inline fn fetchXor(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchXor(intFromEnum(operand), order));
        }

        pub inline fn fetchOr(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return enumFromInt(self.raw.fetchOr(intFromEnum(operand), order));
        }

        pub inline fn rmw(
            self: *Self,
            comptime op: std.builtin.AtomicRmwOp,
            operand: T,
            comptime order: AtomicOrder,
        ) T {
            return enumFromInt(self.rmw(op, intFromEnum(operand), order));
        }
    };
}
