const Trampoline = @This();

const Vtable = struct {
    run: *const fn (self: *anyopaque) void,
};

ptr: *anyopaque,
vtable: *const Vtable,

pub fn run(self: *Trampoline) void {
    self.vtable.run(self.ptr);
}
