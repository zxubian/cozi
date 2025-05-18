//! A thin wrapper around a raw byte buffer aligned
//! according to target architecture requirements.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const cozi = @import("../root.zig");
const log = cozi.core.log.scoped(.stack);

const Stack = @This();

const PtrType = [*]align(alignment_bytes) u8;

slice: []align(alignment_bytes) u8,

pub const alignment_bytes = builtin.target.stackAlignment();
pub const default_size_bytes = 16 * 1024 * 1024;

/// High address
pub fn base(self: *const Stack) PtrType {
    return @alignCast(self.slice.ptr + self.slice.len);
}

/// Low address
pub fn ceil(self: *const Stack) PtrType {
    return @alignCast(self.slice.ptr);
}

pub fn bufferAllocator(self: *const Stack) FixedBufferAllocator {
    return std.heap.FixedBufferAllocator.init(self.slice);
}

pub fn contains(self: *const Stack, address: *anyopaque) bool {
    return @intFromPtr(self.ceil()) <= @intFromPtr(address) and
        @intFromPtr(address) <= @intFromPtr(self.base());
}

/// for debugging only
pub fn print(
    stack: *const Stack,
    offset: usize,
    length: usize,
    stack_pointer: ?*anyopaque,
) void {
    var i: usize = 0;
    std.debug.print("-------\n", .{});
    for (stack.slice[offset .. offset + length]) |r| {
        if (i % 16 == 0) {
            std.debug.print(
                "0x{X:0>8}\t",
                .{@intFromPtr(stack.ceil()) - i},
            );
        }
        std.debug.print("0x{X:0>2}", .{r});
        i += 1;
        if (stack_pointer) |sp| {
            if (@intFromPtr(stack.ceil()) - i == @intFromPtr(sp)) {
                std.debug.print(" <- SP", .{});
            }
        }
        if (i % 16 == 0) {
            std.debug.print("\n", .{});
        } else if (i % 8 == 0) {
            std.debug.print("  ", .{});
        } else {
            std.debug.print(" ", .{});
        }
    }
    std.debug.print("-------\n", .{});
}

pub const Managed = struct {
    raw: Stack,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return initOptions(allocator, .{});
    }

    pub const InitOptions = struct {
        size: usize = default_size_bytes,
    };

    pub fn initOptions(
        allocator: Allocator,
        options: InitOptions,
    ) !Self {
        const size = options.size;
        const buffer = try allocator.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(alignment_bytes),
            size,
        );
        return Self{
            .raw = .{
                .slice = buffer,
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.allocator.free(self.raw.slice);
    }

    pub inline fn top(self: *const Self) PtrType {
        return self.raw.ceil();
    }

    pub inline fn base(self: *const Self) PtrType {
        return self.raw.base();
    }

    pub inline fn bufferAllocator(
        self: *const Self,
    ) FixedBufferAllocator {
        return self.raw.bufferAllocator();
    }

    pub inline fn slice(self: *const Self) []align(alignment_bytes) u8 {
        return self.raw.slice;
    }
};
