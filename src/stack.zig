//! A thin wrapper around raw bytes.
//! Ensures correct alignment, according to target architecture requirements
const std = @import("std");
const builtin = @import("builtin");
const Stack = @This();
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const PtrType = [*]align(ALIGNMENT_BYTES) u8;

ptr: PtrType,
len: usize,

pub const ALIGNMENT_BYTES = builtin.target.stackAlignment();
pub const DEFAULT_SIZE_BYTES = 16 * 1024 * 1024;

pub fn top(self: *const Stack) PtrType {
    return @ptrFromInt(@intFromPtr(self.ptr) + self.len);
}

pub fn base(self: *const Stack) PtrType {
    return self.ptr;
}

pub fn bufferAllocator(self: *const Stack) FixedBufferAllocator {
    return std.heap.FixedBufferAllocator.init(self.ptr[0..self.len]);
}

pub const Managed = struct {
    raw: Stack,
    allocator: Allocator,

    const Self = @This();
    const log = std.log.scoped(.stack);

    pub fn init(allocator: Allocator) !Self {
        return initOptions(allocator, .{});
    }

    pub const InitOptions = struct {
        size: usize = DEFAULT_SIZE_BYTES,
    };

    pub fn initOptions(
        allocator: Allocator,
        options: InitOptions,
    ) !Self {
        const size = options.size;
        const ptr = try allocator.alignedAlloc(
            u8,
            ALIGNMENT_BYTES,
            size,
        );
        return Self{
            .raw = .{
                .ptr = ptr.ptr,
                .len = size,
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.allocator.free(self.raw.ptr[0..self.raw.len]);
    }

    pub inline fn top(self: *const Self) PtrType {
        return self.raw.top();
    }

    pub inline fn bufferAllocator(
        self: *const Self,
    ) FixedBufferAllocator {
        return self.raw.bufferAllocator();
    }
};
