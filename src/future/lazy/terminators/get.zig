const std = @import("std");
const cozi = @import("../../../root.zig");
const State = cozi.future.lazy.State;

const Get = @This();

fn Demand(Future: type) type {
    return struct {
        input_computation: Future.Computation(Continuation) = undefined,
        result: Future.ValueType = undefined,
        ready: std.Thread.ResetEvent = .{},

        pub const Continuation = struct {
            parent: *Demand(Future),
            pub fn @"continue"(
                self: *@This(),
                value: Future.ValueType,
                _: State,
            ) void {
                self.parent.result = value;
                self.parent.ready.set();
            }
        };
    };
}

/// Starts lazy future execution.
/// Blocks current thread until future is completed.
pub fn get(
    future: anytype,
) @TypeOf(future).ValueType {
    const Future = @TypeOf(future);
    var demand: Demand(Future) = .{};
    future.materialize(Demand(Future).Continuation{ .parent = &demand }, &demand.input_computation);
    demand.input_computation.start();
    demand.ready.wait();
    return demand.result;
}
