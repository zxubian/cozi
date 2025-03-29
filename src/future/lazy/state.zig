const std = @import("std");

fn ResultType(ctx: anytype) type {
    const run_function = ctx.run;
    return ReturnType(run_function);
}

fn ReturnType(function: anytype) type {
    const Lambda = @TypeOf(function);
    const lambda_info: std.builtin.Type.Fn = @typeInfo(Lambda).@"fn";
    return lambda_info.return_type.?;
}

pub fn FutureType(Future: type) type {
    return Thunk(Future);
}

fn Demand(V: type) type {
    return struct {
        result: anyerror!V = undefined,
        pub fn @"continue"(
            self: *@This(),
            value: anyerror!V,
            _: State,
        ) void {
            self.result = value;
        }
    };
}

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

pub fn submit(executor: Executor, lambda: anytype) SubmitFuture(ReturnType(lambda)) {
    const V = ReturnType(lambda);
    return SubmitFuture(V){
        .initial_state = .{
            .executor = executor,
        },
        .computation = lambda,
    };
}

pub fn get(future_ptr: anytype) !@TypeOf(future_ptr.*).ValueType {
    const Future = Thunk(@TypeOf(future_ptr.*));
    const V = Future.ValueType;
    var demand: Demand(V) = .{};
    var computation = future_ptr.materialize(&demand);
    computation.start();
    return demand.result;
}

test {
    _ = @import("./tests.zig");
}
