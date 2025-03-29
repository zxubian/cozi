const std = @import("std");
const future = @import("../main.zig");
const model = future.model;
const Thunk = model.Thunk;
const Demand = @import("./main.zig").Demand;

const Get = @This();

pub fn get(
    future_: anytype,
) !@TypeOf(future_).ValueType {
    const Future = Thunk(@TypeOf(future_));
    const V = Future.ValueType;
    var demand: Demand(V) = .{};
    var computation = future_.materialize(&demand);
    computation.start();
    return demand.result;
}
