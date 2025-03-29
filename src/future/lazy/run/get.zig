const std = @import("std");
const future = @import("../main.zig");
const model = future.model;
const Thunk = model.Thunk;
const Demand = @import("./main.zig").Demand;

pub fn get(future_ptr: anytype) !@TypeOf(future_ptr.*).ValueType {
    const Future = Thunk(@TypeOf(future_ptr.*));
    const V = Future.ValueType;
    var demand: Demand(V) = .{};
    var computation = future_ptr.materialize(&demand);
    computation.start();
    return demand.result;
}
