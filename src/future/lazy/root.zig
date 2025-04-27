//! Lazily-evaluated futures
const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../root.zig").executors;
const Executor = executors.Executor;
const core = @import("../../root.zig").core;
const Runnable = core.Runnable;

/// Lazily-evaluated futures
// --- external re-exports ---
pub const Impl = struct {
    // --- generators ---
    pub const submit = make.submit.submit;
    pub const Submit = make.submit.Future;
    pub const just = make.just.just;
    pub const constValue = make.constValue.constValue;
    pub const Value = make.value.vture;
    pub const value = make.value.value;
    pub const contract = make.contract.contract;
    pub const contractNoAlloc = make.contract.contractNoAlloc;
    pub const Contract = make.contract.Contract;
    // --- sequential combinators ---
    pub const via = combinators.via.via;
    pub const map = combinators.map.map;
    pub const mapOk = combinators.mapOk.mapOk;
    pub const andThen = combinators.andThen.andThen;
    pub const orElse = combinators.orElse.orElse;
    pub const flatten = combinators.flatten.flatten;
    pub const box = combinators.box.box;
    pub const Boxed = combinators.box.BoxedFuture;
    pub const Box = combinators.box.Future;
    // --- parallel combinators ---
    pub const all = combinators.all.all;
    pub const All = combinators.all.All;
    pub const first = combinators.first.first;
    pub const First = combinators.first.First;
    // --- terminators ---
    pub const get = terminators.get;
    pub const detach = terminators.detach;
    // --- syntax ---
    pub const pipeline = syntax.pipeline.pipeline;
};

// --- internal implementation ---
pub const meta = @import("./meta.zig");
pub const make = @import("./make/root.zig");
pub const terminators = @import("./terminators//root.zig");
pub const combinators = @import("./combinators/root.zig");
pub const syntax = @import("./syntax/root.zig");

pub const State = struct {
    executor: Executor,
};

pub fn Continuation(V: type) type {
    return struct {
        const Vtable = struct {
            @"continue": *const fn (self: *anyopaque, value: V, state: State) void,
        };
        vtable: Vtable,
        ptr: *anyopaque,

        pub fn @"continue"(
            self: @This(),
            value: V,
            state: State,
        ) void {
            self.vtable.@"continue"(self.ptr, value, state);
        }

        pub fn eraseType(ptr: anytype) @This() {
            const Ptr = @TypeOf(ptr);
            const ptr_info: std.builtin.Type.Pointer = @typeInfo(Ptr).pointer;
            const T = ptr_info.child;
            return .{
                .ptr = @alignCast(@ptrCast(ptr)),
                .vtable = .{
                    .@"continue" = @ptrCast(&T.@"continue"),
                },
            };
        }
    };
}

test {
    _ = @import("./tests.zig");
}
