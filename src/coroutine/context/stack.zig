//! A thin wrapper around raw bytes.
//! Ensures correct alignment, according to target architecture requirements
const std = @import("std");
const builtin = @import("builtin");
const Stack = @This();
const Allocator = std.mem.Allocator;

const PtrType = [*]align(STACK_ALIGNMENT_BYTES) u8;

ptr: PtrType,
len: usize,
allocator: Allocator,

const STACK_ALIGNMENT_BYTES = builtin.target.stackAlignment();

pub fn bottom(self: *const Stack) PtrType {
    return @ptrFromInt(@intFromPtr(self.ptr) + self.len);
}

pub const InitOptions = struct {
    const DEFAULT_STACK_SIZE_BYTES = 16 * 1024 * 1024;
    size: usize = DEFAULT_STACK_SIZE_BYTES,
};

pub fn init(allocator: Allocator) !Stack {
    return initOptions(.{}, allocator);
}

pub fn initOptions(options: InitOptions, allocator: Allocator) !Stack {
    const size = options.size;
    const ptr = try allocator.alignedAlloc(u8, STACK_ALIGNMENT_BYTES, size);
    return Stack{
        .ptr = ptr.ptr,
        .len = size,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Stack) void {
    self.allocator.free(self.ptr[0..self.len]);
    self.len = 0;
    self.ptr = undefined;
}
