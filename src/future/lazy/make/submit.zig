const std = @import("std");
const assert = std.debug.assert;
const executors = @import("../../../main.zig").executors;
const Executor = executors.Executor;
const core = @import("../../../main.zig").core;
const Runnable = core.Runnable;
const future = @import("../main.zig");
const State = future.State;
const model = future.model;
const Computation = model.Computation;
const meta = future.meta;

fn SubmitFuture(V: type) type {
    return struct {
        pub const ValueType = V;
        computation: *const fn () ValueType,
        initial_state: State,

        fn SubmitComputation(Continuation: anytype) type {
            return struct {
                executor: Executor,
                computation: *const fn () ValueType,
                wait_group: std.Thread.WaitGroup = .{},
                result: V = undefined,
                continuation: Continuation,

                pub fn start(self: *@This()) void {
                    var runnable = self.makeRunnable();
                    self.wait_group.startMany(2);
                    self.executor.submitRunnable(&runnable);
                    self.wait_group.finish();
                    self.wait_group.wait();
                    self.continuation.@"continue"(self.result, .{
                        .executor = self.executor,
                    });
                }

                pub fn makeRunnable(self: *@This()) Runnable {
                    return Runnable{
                        .runFn = @This().run,
                        .ptr = self,
                    };
                }

                pub fn run(ctx: *anyopaque) void {
                    const self: *@This() = @alignCast(@ptrCast(ctx));
                    self.result = self.computation();
                    self.wait_group.finish();
                }
            };
        }

        pub fn materialize(
            self: *@This(),
            continuation: anytype,
        ) Computation(SubmitComputation(@TypeOf(continuation))) {
            return .{
                .executor = self.initial_state.executor,
                .computation = self.computation,
                .continuation = continuation,
            };
        }
    };
}

pub fn submit(executor: Executor, lambda: anytype) SubmitFuture(meta.ReturnType(lambda)) {
    const V = meta.ReturnType(lambda);
    return SubmitFuture(V){
        .initial_state = .{
            .executor = executor,
        },
        .computation = lambda,
    };
}
