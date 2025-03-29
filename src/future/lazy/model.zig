const std = @import("std");
const assert = std.debug.assert;
const Future = @import("./main.zig");
const State = Future.State;

pub fn ValidateComputation(T: type) void {
    assert(std.meta.activeTag(@typeInfo(T)) == .@"struct");
    assert(@TypeOf(T.start) == *const fn () void);
}

pub fn Computation(T: type) type {
    return T;
}

pub fn ValidateContinuation(T: type) void {
    assert(@typeInfo(T) == .Struct);
    const V: type = T.ValueType;
    assert(@TypeOf(T.@"continue") == *const fn (V, State) void);
}

pub fn ValidateThunk(T: type) void {
    assert(std.meta.activeTag(@typeInfo(T)) == .@"struct");
    // const materialize = T.materialize;
    // @compileLog(@typeInfo(@TypeOf(materialize)));
    // const MaterializeReturnType = ReturnType(materialize);
    // TODO: currently in zig return type is null as materialize is generic
    // ValidateComputation(MaterializeReturnType);
}

pub fn Thunk(T: type) type {
    ValidateThunk(T);
    return T;
}
