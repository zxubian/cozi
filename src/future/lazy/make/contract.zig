const std = @import("std");
const assert = std.debug.assert;

const cozi = @import("../../../root.zig");
const executors = cozi.executors;
const core = cozi.core;
const Runnable = core.Runnable;
const future = cozi.future.lazy;
const atomic = cozi.fault.stdlike.atomic;

pub fn Contract(V: type) type {
    return struct {
        pub const Tuple = std.meta.Tuple(&[_]type{ Future, Promise });

        pub const Future = struct {
            shared_state: SharedStateInterface,

            pub const ValueType = V;

            pub fn Computation(Continuation: type) type {
                return struct {
                    shared_state: SharedStateInterface,
                    next: Continuation,

                    pub fn start(self: *@This()) void {
                        self.shared_state.onFutureArrived(
                            future.Continuation(V).eraseType(&self.next),
                        );
                    }
                };
            }

            pub fn materialize(
                self: @This(),
                continuation: anytype,
                computation_storage: *Computation(@TypeOf(continuation)),
            ) void {
                computation_storage.* = .{
                    .shared_state = self.shared_state,
                    .next = continuation,
                };
            }

            pub fn awaitable(self: @This()) future.Awaitable(@This()) {
                return .{
                    .future = self,
                };
            }
        };

        pub const Promise = struct {
            shared_state: SharedStateInterface,

            pub fn resolve(
                self: *const @This(),
                value: V,
            ) void {
                self.shared_state.onPromiseArrived(value);
            }
        };

        pub const SharedState = SharedStateImpl(false);

        fn SharedStateImpl(managed: bool) type {
            return struct {
                continuation: future.Continuation(V) = undefined,
                state: atomic.Value(u8) = .init(@intFromEnum(State.init)),
                value: V = undefined,
                allocator: blk: {
                    if (managed) {
                        break :blk std.mem.Allocator;
                    } else {
                        break :blk void;
                    }
                } = blk: {
                    if (managed) {
                        break :blk undefined;
                    } else {
                        break :blk {};
                    }
                },

                pub const State = enum(u8) {
                    init = 0,
                    promise_arrived = 1 << 0,
                    future_arrived = 1 << 1,
                    rendezvous = 3,
                };

                pub fn onFutureArrived(
                    self: *@This(),
                    continuation: future.Continuation(V),
                ) void {
                    switch (@as(State, @enumFromInt(self.state.fetchOr(
                        @intFromEnum(State.future_arrived),
                        .seq_cst,
                    )))) {
                        .init => {
                            self.continuation = continuation;
                        },
                        .promise_arrived => {
                            continuation.@"continue"(
                                self.value,
                                .init,
                            );
                            if (managed) {
                                self.allocator.destroy(self);
                            }
                        },
                        else => std.debug.panic("Attempting to get future result twice.", .{}),
                    }
                }

                pub fn onPromiseArrived(self: *@This(), value: V) void {
                    switch (@as(State, @enumFromInt(self.state.fetchOr(
                        @intFromEnum(State.promise_arrived),
                        .seq_cst,
                    )))) {
                        .init => self.value = value,
                        .future_arrived => {
                            self.continuation.@"continue"(
                                value,
                                .init,
                            );
                            if (managed) {
                                self.allocator.destroy(self);
                            }
                        },
                        else => std.debug.panic("Attempting to resolve promise twice.", .{}),
                    }
                }
            };
        }
        const SharedStateInterface = struct {
            ptr: *anyopaque,
            vtable: Vtable,

            const Vtable = struct {
                on_future_arrived: *const fn (
                    self: *anyopaque,
                    continuation: future.Continuation(V),
                ) void,
                on_promise_arrived: *const fn (self: *anyopaque, value: V) void,
            };

            pub inline fn onFutureArrived(
                self: @This(),
                continuation: future.Continuation(V),
            ) void {
                self.vtable.on_future_arrived(self.ptr, continuation);
            }

            pub inline fn onPromiseArrived(self: @This(), value: V) void {
                self.vtable.on_promise_arrived(self.ptr, value);
            }

            pub fn eraseType(shared_state_ptr: anytype) @This() {
                const T = @typeInfo(@TypeOf(shared_state_ptr)).pointer.child;
                return .{
                    .ptr = @ptrCast(shared_state_ptr),
                    .vtable = .{
                        .on_future_arrived = @ptrCast(&T.onFutureArrived),
                        .on_promise_arrived = @ptrCast(&T.onPromiseArrived),
                    },
                };
            }
        };
    };
}

/// Create a connected Future-Promise pair.
/// Returns a `std.meta.Tuple` of the type .{Future, Promise}.
/// The memory necessary for SharedState is automatically
/// allocated on creation and deallocated on rendezvous
/// using the provided `allocator`.
pub fn contract(
    V: type,
    allocator: std.mem.Allocator,
) !Contract(V).Tuple {
    const ContractType = Contract(V);
    // alloction is required as lifetimes of Promise & Future are unknown
    const shared_state = try allocator.create(ContractType.SharedStateImpl(true));
    shared_state.* = .{ .allocator = allocator };
    const type_erased = Contract(V).SharedStateInterface.eraseType(shared_state);
    return .{
        .{
            .shared_state = type_erased,
        },
        .{
            .shared_state = type_erased,
        },
    };
}

/// Create a connected Future-Promise pair.
/// Returns a `std.meta.Tuple` of the type .{Future, Promise}.
/// Callee owns shared_state memory.
pub fn contractNoAlloc(
    V: type,
    shared_state: *Contract(V).SharedState,
) Contract(V).Tuple {
    const type_erased = Contract(V).SharedStateInterface.eraseType(shared_state);
    return .{
        .{
            .shared_state = type_erased,
        },
        .{
            .shared_state = type_erased,
        },
    };
}
