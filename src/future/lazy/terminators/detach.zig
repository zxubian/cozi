const std = @import("std");
const future_ = @import("../root.zig");
const State = future_.State;
const GetStorageType = future_.Storage;

const Get = @This();

fn Demand(Future: type) type {
    return struct {
        pub const Continuation = struct {
            allocator: std.mem.Allocator,
            computation: *Future.Computation(@This()),

            pub fn @"continue"(
                self: *@This(),
                _: Future.ValueType,
                _: State,
            ) void {
                self.allocator.destroy(self.computation);
            }
        };
    };
}

/// Starts lazy future execution.
/// Current thread will continue execution.
pub fn detach(
    future: anytype,
    allocator: std.mem.Allocator,
) !void {
    const Future = @TypeOf(future);
    const DemandType = Demand(Future);
    const Continuation = DemandType.Continuation;
    const computation = try allocator.create(Future.Computation(Continuation));
    computation.* = future.materialize(
        Continuation{
            .allocator = allocator,
            .computation = computation,
        },
    );
    computation.start();
}
