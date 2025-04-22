const std = @import("std");
const assert = std.debug.assert;
const future = @import("../root.zig");
const model = future.model;
const meta = future.meta;
const executors = @import("../../../root.zig").executors;

pub fn Contract(V: type) type {
    return struct {
        pub const Tuple = std.meta.Tuple(&[_]type{ Future, Promise });

        pub const Future = struct {
            shared_state: *SharedState,

            pub const ValueType = V;

            pub fn Computation(Continuation: type) type {
                return struct {
                    shared_state: *SharedState,
                    next: Continuation,

                    pub fn start(self: *@This()) void {
                        self.shared_state.onFutureArrived(
                            future.Continuation(V).fromType(&self.next),
                        );
                    }
                };
            }

            pub fn materialize(
                self: @This(),
                continuation: anytype,
            ) Computation(@TypeOf(continuation)) {
                return .{
                    .shared_state = self.shared_state,
                    .next = continuation,
                };
            }
        };

        pub const Promise = struct {
            shared_state: *SharedState,

            pub fn resolve(
                self: *const @This(),
                value: V,
            ) void {
                self.shared_state.onPromiseArrived(value);
            }
        };
        pub const SharedState = struct {
            continuation: future.Continuation(V) = undefined,
            state: std.atomic.Value(u8) = .init(@intFromEnum(State.init)),
            value: V = undefined,
            allocator: std.mem.Allocator,

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
                            future.State{
                                .executor = executors.@"inline",
                            },
                        );
                        self.allocator.destroy(self);
                    },
                    else => std.debug.panic("Attempting to resolve promise twice.", .{}),
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
                            future.State{
                                .executor = executors.@"inline",
                            },
                        );
                        self.allocator.destroy(self);
                    },
                    else => std.debug.panic("Attempting to resolve promise twice.", .{}),
                }
            }
        };
    };
}

// TODO: add noalloc variant
/// Create a connected Future-Promise pair.
/// Returns tuple containing [Future, Promise].
pub fn contractManaged(
    V: type,
    allocator: std.mem.Allocator,
) !Contract(V).Tuple {
    const ContractType = Contract(V);
    // alloction is required as lifetimes of Promise & Future are unknown
    const shared_state = try allocator.create(ContractType.SharedState);
    shared_state.* = .{ .allocator = allocator };
    return .{
        .{
            .shared_state = shared_state,
        },
        .{
            .shared_state = shared_state,
        },
    };
}
