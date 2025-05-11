const std = @import("std");
const cozi = @import("../../../root.zig");
const future = cozi.future.lazy;

const Get = @This();

fn Demand(Future: type) type {
    return struct {
        result: Future.ValueType = undefined,
        ready: std.Thread.ResetEvent = .{},
        cancel_state: future.cancel.State = .{},

        pub const Continuation = struct {
            parent: *Demand(Future),
            cancel_ctx: future.cancel.Context = undefined,
            state: cozi.fault.stdlike.atomic.Value(State) = .init(.init),

            const State = enum(u8) {
                init,
                resolved,
                canceled,
            };

            const is_cancellable: bool = blk: {
                const result_type_info = @typeInfo(Future.ValueType);
                if (result_type_info != .error_union) {
                    break :blk false;
                }
                break :blk true;
            };

            pub fn @"continue"(
                self: *@This(),
                value: Future.ValueType,
                _: future.State,
            ) void {
                if (self.state.cmpxchgStrong(
                    .init,
                    .resolved,
                    .seq_cst,
                    .seq_cst,
                )) |state| {
                    switch (state) {
                        .canceled => {
                            // lost the race
                            return;
                        },
                        .resolved => std.debug.panic("Resolving future twice", .{}),
                        else => unreachable,
                    }
                }
                self.parent.result = value;
                self.parent.ready.set();
            }

            pub fn init(self: *@This()) void {
                if (is_cancellable) {
                    self.cancel_ctx.init(
                        self,
                        &self.parent.cancel_state,
                    );
                }
            }

            pub fn onCancel(self: *@This()) void {
                if (!is_cancellable) {
                    return;
                }
                if (self.state.cmpxchgStrong(
                    .init,
                    .canceled,
                    .seq_cst,
                    .seq_cst,
                )) |state| {
                    switch (state) {
                        .resolved => {
                            // lost the race
                            return;
                        },
                        .canceled => std.debug.panic("Cancelling future twice", .{}),
                        else => unreachable,
                    }
                }
                self.parent.result = future.cancel.CancellationError.canceled;
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
        Demand(Future).Continuation{
            .parent = &demand,
        },
    );
    computation.init();
    computation.start();
    demand.ready.wait();
    return demand.result;
}
