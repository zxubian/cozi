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

fn BoxedComputation(V: type) type {
    return struct {
        const Impl = @This();
        allocator: std.mem.Allocator,
        contents: *Contents,
        vtable: Vtable,
        const Contents = struct {
            const Computation = struct {
                raw_bytes: []u8,
                alignment: u29,

                inline fn ptr(self: @This()) *anyopaque {
                    return @alignCast(@ptrCast(self.raw_bytes.ptr));
                }

                pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
                    allocator.rawFree(
                        self.raw_bytes,
                        std.mem.Alignment.fromByteUnits(self.alignment),
                        @returnAddress(),
                    );
                }
            };
            input_computation: Computation,
            continuation: future.Continuation(V) = undefined,

            pub fn init(allocator: std.mem.Allocator, InputComputation: type) !*@This() {
                const computation_ptr = try allocator.create(InputComputation);
                const raw_bytes = std.mem.asBytes(computation_ptr);
                const ptr = try allocator.create(@This());
                ptr.* = .{
                    .input_computation = Computation{
                        .raw_bytes = raw_bytes,
                        .alignment = @alignOf(InputComputation),
                    },
                };
                return ptr;
            }

            pub fn inputComputation(self: @This(), ComputationType: type) *ComputationType {
                return std.mem.bytesAsValue(
                    ComputationType,
                    @as(
                        []align(@alignOf(ComputationType)) u8,
                        @alignCast(
                            @ptrCast(
                                self.input_computation.raw_bytes,
                            ),
                        ),
                    ),
                );
            }

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.input_computation.deinit(allocator);
                allocator.destroy(self);
            }
        };

        const Vtable = struct {
            start: *const fn (self: *anyopaque) void,
        };

        pub fn init(f: anytype, allocator: std.mem.Allocator) !@This() {
            const InputFuture = @TypeOf(f);
            const OutputValue = InputFuture.ValueType;
            comptime assert(OutputValue == V);
            const InputContinuation = BoxedFuture(OutputValue).InputContinuation;
            const InputComputation = InputFuture.Computation(InputContinuation);
            const boxed: Impl = .{
                .allocator = allocator,
                .contents = try Contents.init(allocator, InputComputation),
                .vtable = .{
                    .start = @ptrCast(&InputComputation.start),
                },
            };
            const input_computation = boxed.contents.inputComputation(InputComputation);
            input_computation.* = f.materialize(
                InputContinuation{
                    .boxed_input_computation = boxed,
                },
            );
            return boxed;
        }

        pub inline fn start(self: @This()) void {
            self.vtable.start(self.contents.input_computation.ptr());
        }

        pub inline fn deinit(self: @This()) void {
            self.contents.deinit(self.allocator);
        }
    };
}

pub fn BoxedFuture(V: type) type {
    return struct {
        pub const ValueType = V;
        const BoxedFutureType = @This();
        boxed_input_computation: BoxedComputation(V),

        pub fn Computation(Continuation: type) type {
            return struct {
                boxed_input_computation: BoxedComputation(V),
                next: Continuation,

                const Impl = @This();

                pub fn start(self: *@This()) void {
                    self.boxed_input_computation.contents.continuation = future
                        .Continuation(ValueType)
                        .eraseType(&self.next);
                    self.boxed_input_computation.start();
                }
            };
        }

        pub const InputContinuation = struct {
            boxed_input_computation: BoxedComputation(V),
            value: V = undefined,
            state: State = undefined,
            runnable: Runnable = undefined,

            pub fn @"continue"(
                self: *@This(),
                value: V,
                state: State,
            ) void {
                self.value = value;
                self.state = state;
                self.runnable = .{
                    .runFn = runContinue,
                    .ptr = self,
                };
                state.executor.submitRunnable(&self.runnable);
            }

            pub fn runContinue(ctx: *anyopaque) void {
                const self: *@This() = @alignCast(@ptrCast(ctx));
                self.boxed_input_computation.contents.continuation.@"continue"(
                    self.value,
                    self.state,
                );
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

// used for piping
pub fn Future(F: type) type {
    return BoxedFuture(F.ValueType);
}

pub fn pipe(
    self: *const Box,
    f: anytype,
) Future(@TypeOf(f)) {
    const InputFuture = @TypeOf(f);
    const boxed_input_computation = BoxedComputation(InputFuture.ValueType).init(f, self.allocator) catch unreachable;
    return Future(InputFuture){
        .boxed_input_computation = boxed_input_computation,
    };
}

/// Use allocator to create a container for storing the piped future's computation.
/// The container is self-destructed when the future is resolved (e.g. via `get`).
/// The type of piped future is erased to a BoxedFuture<V> interface.
/// F<V> -> BoxedFuture<V>
pub fn box(allocator: std.mem.Allocator) Box {
    return .{ .allocator = allocator };
}
