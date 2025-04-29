const Trampoline = @This();

pub const Vtable = struct {
    run: *const fn (self: *anyopaque) noreturn,
};

ptr: *anyopaque,
vtable: *const Vtable,

pub fn run(self: *Trampoline) noreturn {
    self.vtable.run(self.ptr);
}

// intended for calling from assembly
pub fn runC(ctx: *anyopaque) callconv(.C) noreturn {
    const self: *Trampoline = @alignCast(@ptrCast(ctx));
    self.vtable.run(self.ptr);
}
