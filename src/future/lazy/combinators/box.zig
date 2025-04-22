const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../root.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../root.zig").core;
const Runnable = core.Runnable;
const future = @import("../root.zig");
const State = future.State;

allocator: std.mem.Allocator,

const Box = @This();

const BoxedComputation = struct {
    computation_ptr: *anyopaque,
    vtable: Vtable,
    allocator: std.mem.Allocator,

    const Vtable = struct {
        start: *const fn (self: *anyopaque) void,
    };

    pub fn init(f: anytype, allocator: std.mem.Allocator) !@This() {
        const InputFuture = @TypeOf(f);
        const OutputValue = InputFuture.ValueType;
        const InputContinuation = Future(OutputValue).InputContinuation;
        const InputComputation = InputFuture.Computation(InputContinuation);
        const input_computation = try allocator.create(InputComputation);
        const boxed: @This() = .{
            .computation_ptr = input_computation,
            .vtable = .{
                .start = @ptrCast(&InputComputation.start),
            },
            .allocator = allocator,
        };
        input_computation.* = f.materialize(
            InputContinuation{
                .boxed_input_computation = boxed,
            },
        );
        return boxed;
    }

    pub inline fn start(self: @This()) void {
        self.vtable.start(self.computation_ptr);
    }

    pub inline fn deinit(self: @This()) void {
        self.allocator.destroy(self.computation_ptr);
    }
};

pub fn Future(V: type) type {
    return struct {
        pub const ValueType = V;
        const BoxedFutureType = @This();
        boxed_input_computation: BoxedComputation,

        pub fn Computation(Continuation: type) type {
            return struct {
                const ComputationType = @This();

                boxed_input_computation: BoxedComputation,
                next: Continuation,

                pub fn start(self: *@This()) void {
                    self.boxed_input_computation.start();
                }
            };
        }

        pub const InputContinuation = struct {
            boxed_input_computation: BoxedComputation,
            pub fn @"continue"(
                self: *@This(),
                value: V,
                state: State,
            ) void {
                _ = value;
                _ = state;
                self.boxed_input_computation.deinit();
            }
        };

        pub fn materialize(
            self: @This(),
            continuation: anytype,
        ) Computation(@TypeOf(continuation)) {
            return .{
                .next = continuation,
                .boxed_input_computation = self.boxed_input_computation,
            };
        }
    };
}

/// F<V> -> BoxedFuture<V>
pub fn pipe(
    self: *const Box,
    f: anytype,
) Future(@TypeOf(f).ValueType) {
    const InputFuture = @TypeOf(f);
    const OutputValue = InputFuture.ValueType;
    const boxed_input_computation = BoxedComputation.init(f, self.allocator) catch unreachable;
    return Future(OutputValue){ .boxed_input_computation = boxed_input_computation };
}

pub fn box(allocator: std.mem.Allocator) Box {
    return .{ .allocator = allocator };
}
