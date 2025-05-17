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
            cancel_source: future.cancel.Source,

            pub const ValueType = V;

            pub fn Computation(Continuation: type) type {
                return struct {
                    shared_state: SharedStateInterface,
                    next: Continuation,
                    cancel_ctx: future.cancel.LinkedContext,

                    pub fn init(self: *@This()) void {
                        self.cancel_ctx.init(
                            self,
                            self.shared_state.cancel_state,
                        );
                        self.next.init();
                        self.cancel_ctx.linkTo(self.next.cancel_ctx);
                    }

                    pub fn start(self: *@This()) void {
                        if (self.cancel_ctx.isCanceled()) {
                            return;
                        }
                        const continuation = future.Continuation(V).eraseType(
                            &self.next,
                        );
                        self.shared_state.onFutureArrived(continuation);
                    }

                    pub fn onCancel(self: *@This()) void {
                        const continuation = future.Continuation(V).eraseType(
                            &self.next,
                        );
                        self.shared_state.onCancel(continuation);
                    }
                };
            }

            pub fn materialize(
                self: @This(),
                continuation: anytype,
            ) Computation(@TypeOf(continuation)) {
                return .{
                    .shared_state = self.shared_state,
                    .cancel_source = self.cancel_source,
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
            cancel_token: future.cancel.Token,

            pub fn resolve(
                self: *const @This(),
                value: V,
            ) void {
                self.shared_state.onPromiseArrived(value);
            }

            pub fn isCanceled(self: @This()) bool {
                return self.cancel_token.isCanceled();
            }

            pub fn subscribeOnCancel(
                self: @This(),
                callback: *future.cancel.Callback,
            ) void {
                self.cancel_token.subscribe(callback);
            }

            pub fn seal(self: @This()) void {
                self.shared_state.onPromiseArrived(undefined);
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
                cancel_state: future.cancel.State = .{},

                pub const State = enum(u8) {
                    init = 0,
                    promise_arrived = 1 << 0,
                    future_arrived = 1 << 1,
                    canceled = 1 << 2,
                    rendezvous = 1 + (1 << 1),
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
                            if (managed) {
                                self.allocator.destroy(self);
                            }
                            continuation.@"continue"(
                                self.value,
                                .init,
                            );
                        },
                        .canceled => {},
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
                            if (managed) {
                                self.allocator.destroy(self);
                            }
                            self.continuation.@"continue"(
                                value,
                                .init,
                            );
                        },
                        .canceled => {
                            if (managed) {
                                self.allocator.destroy(self);
                            }
                        },
                        else => std.debug.panic("Attempting to resolve promise twice.", .{}),
                    }
                }

                pub fn onCancel(
                    self: *@This(),
                    continuation: future.Continuation(V),
                ) void {
                    switch (@as(State, @enumFromInt(self.state.fetchOr(
                        @intFromEnum(State.canceled),
                        .seq_cst,
                    )))) {
                        .init => {
                            continuation.@"continue"(
                                undefined,
                                .init,
                            );
                        },
                        .promise_arrived => {
                            if (managed) {
                                self.allocator.destroy(self);
                            }
                            continuation.@"continue"(
                                undefined,
                                .init,
                            );
                        },
                        .canceled => {
                            std.debug.panic("canceling twice", .{});
                        },
                        else => {},
                    }
                }
            };
        }

        const SharedStateInterface = struct {
            ptr: *anyopaque,
            cancel_state: *future.cancel.State,
            vtable: Vtable,

            const Vtable = struct {
                on_future_arrived: *const fn (
                    self: *anyopaque,
                    continuation: future.Continuation(V),
                ) void,
                on_promise_arrived: *const fn (
                    self: *anyopaque,
                    value: V,
                ) void,
                on_cancel: *const fn (
                    self: *anyopaque,
                    continuation: future.Continuation(V),
                ) void,
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

            pub inline fn onCancel(
                self: @This(),
                continuation: future.Continuation(V),
            ) void {
                self.vtable.on_cancel(self.ptr, continuation);
            }

            pub fn eraseType(shared_state_ptr: anytype) @This() {
                const T = @typeInfo(@TypeOf(shared_state_ptr)).pointer.child;
                return .{
                    .ptr = @ptrCast(shared_state_ptr),
                    .vtable = .{
                        .on_future_arrived = @ptrCast(&T.onFutureArrived),
                        .on_promise_arrived = @ptrCast(&T.onPromiseArrived),
                        .on_cancel = @ptrCast(&T.onCancel),
                    },
                    .cancel_state = &shared_state_ptr.cancel_state,
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
            .cancel_source = .{
                .state = &shared_state.cancel_state,
            },
        },
        .{
            .shared_state = type_erased,
            .cancel_token = .{
                .state = &shared_state.cancel_state,
            },
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
            .cancel_source = .{
                .state = &shared_state.cancel_state,
            },
        },
        .{
            .shared_state = type_erased,
            .cancel_token = .{
                .state = &shared_state.cancel_state,
            },
        },
    };
}
