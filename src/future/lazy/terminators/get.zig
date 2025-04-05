const std = @import("std");
const future_ = @import("../main.zig");
const State = future_.State;
const GetStorageType = future_.Storage;

const Get = @This();

fn Demand(Future: type) type {
    return struct {
        result: Future.ValueType = undefined,
        ready: std.Thread.ResetEvent = .{},
        pub fn @"continue"(
            self: *@This(),
            value: Future.ValueType,
            _: State,
        ) void {
            self.ready.set();
            self.result = value;
        }
    };
}

/// Starts lazy future execution.
/// Blocks current thread until future is completed.
pub fn get(
    future: anytype,
) @TypeOf(future).ValueType {
    const Future = @TypeOf(future);
    var demand: Demand(Future) = .{};
    var computation = future.materialize(&demand);
    computation.start();
    demand.ready.wait();
    return demand.result;
}
