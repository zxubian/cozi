const std = @import("std");
const cozi = @import("../../../root.zig");
const State = cozi.future.lazy.State;
const future = cozi.future.lazy;

const Get = @This();

fn Demand(Future: type) type {
    return struct {
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
    any_future: anytype,
) @TypeOf(any_future).ValueType {
    const Future = @TypeOf(any_future);
    var demand: Demand(Future) = .{};
    var computation = any_future.materialize(
        Demand(Future).Continuation{ .parent = &demand },
    );
    computation.start();
    demand.ready.wait();
    return demand.result;
}

pub fn getWithCancellation(
    any_future: anytype,
    cancel_token: future.cancel.Token,
) future.cancel.CancellationError!@TypeOf(any_future.ValueType) {
    const Future = @TypeOf(any_future);
    var demand: Demand(Future) = .{};
    var cancel_state: future.cancel.State = .{};
    var cancel_source: future.cancel.Source = .{
        .state = &cancel_state,
    };
    var source_callback = cancel_source.getCancelAsCallback();
    cancel_token.subscribe(&source_callback);
    var computation = any_future.materialize(
        Demand(Future).Continuation{
            .parent = &demand,
        },
    );
    computation.start();
    demand.ready.wait();
    return demand.result;
}
