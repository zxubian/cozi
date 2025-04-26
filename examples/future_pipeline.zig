const std = @import("std");
const cozi = @import("cozi");
const ThreadPool = cozi.executors.ThreadPools.Compute;
const future = cozi.future.lazy;
const assert = std.debug.assert;

pub fn main() !void {
    // Define asynchronous pipeline
    // At this point, `p`'s computation does not start executing.
    // `p` only represents the desired sequence of computations
    // to be executed some time later, when `p`' is evaluated.
    // No heap allocations happen at this point.
    const p = future.pipeline(
        .{
            future.constValue(@as(usize, 123)),
            future.map(
                struct {
                    pub fn run(_: ?*anyopaque, in: usize) usize {
                        return in + 1;
                    }
                }.run,
                null,
            ),
        },
    );

    // ...
    // do something else (e.g. pass `p` between functions)
    // ...

    // Evaluate `p`, obtaining the result of the computation pipeline.
    // no heap allocations happen at this point.
    // The necessary memory for evaluating `p` and executing
    // the pipeline's computations is acquired from the stack
    // at the callsite of `future.get`
    // This thread is blocked until `p`'s computations complete.
    const result = future.get(p);
    assert(result == 124);
}
