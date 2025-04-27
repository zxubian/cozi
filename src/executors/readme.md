# Executors & Schedulers
## [Executor](/src/executors/executor.zig)
- `Executor` is a type-erased interface representing an abstract task queue.
- `Executor` allows users to submit [Runnable](/src/core/runnable.zig)s (an abstract representation a task) for eventual execution.

```zig
const executor = thread_pool.executor();
executor.submit(some_function, .{args}, allocator);
// eventually, some_function(args) will be called.
// exact timing depends on the specific Executor implementation
```

- `Executor` is to asynchronous task execution what [Allocator](https://github.com/ziglang/zig/blob/master/lib/std/mem/Allocator.zig) is to memory management.
- `Executor` is a fundamental building block, and many other primitives of this library expose APIs compatible with it 
    - both `Future` and `Fiber` can run on any `Executor`
- this abstraction allows us to orthogonally separate _what_ is being executed (tasks, futures, fibers, etc. ) from _how_ it is run (in a single-threaded manual event loop, a thread pool, etc.)

## Available Executors:
### [Inline](/src/executors/inline.zig)
```zig
const inline_executor = cozi.executors.@"inline";
const Ctx = struct {
    done: bool,
    pub fn run(self: *@This()) void {
        self.done = true;
    }
};
var ctx: Ctx = .{ .done = false };
// on submit, Ctx.run(&ctx) is executed immediately
try inline_executor.submit(Ctx.run, .{&ctx}, std.testing.allocator);
try std.testing.expect(ctx.done);
```
### [Manual](/src/executors/manual.zig)
-  Single-threaded manually-executed task queue
```zig
const ManualExecutor = cozi.executors.Manual;
var manual = ManualExecutor{};
const Ctx = struct {
  step: usize,
  pub fn run(self: *@This()) void {
      self.step += 1;
  }
};
var ctx: Ctx = .{.step = 0};
const executor = manual.executor();
// on `submit`, task is added to the queue,
// but not executed yet
for (0..4) |_| {
    executor.submit(Step.run, .{&step}, allocator);
}
try testing.expectEqual(0, ctx.step);
// users can manually control execution,
// and specify how many tasks to run at a time 
try expect(manual.runNext());
try expectEqual(2, manual.runAtMost(2));
try expectEqual(1, manual.drain());
try expectEqual(4, ctx.step);
```

### [Thread Pool](/src/executors/threadPool/compute.zig)
#### Properties:
- single task queue, shared between all worker threads (more sophisticated thread pool with threadlocal queues & work-stealing is [planned](https://github.com/zxubian/cozi/issues/13))
- intrusive linked list as basis for task queue (thread pool itself does not allocate on task `submit`)
- customizable stack size for worker threads

```zig
const ThreadPool = cozi.executors.threadPools.Compute;
// Create fixed number of "worker threads" at init time.
var thread_pool = try ThreadPool.init(4, allocator);
defer thread_pool.deinit();
try thread_pool.start();
defer thread_pool.stop();

const Ctx = struct {
    wait_group: std.Thread.WaitGroup = .{},
    sum: std.atomic.Value(usize) = .init(0),

    pub fn run(self: *@This()) void {
        _ = self.sum.fetchAdd(1, .seq_cst);
        self.wait_group.finish();
    }
};

var ctx: Ctx = .{};
const task_count = 4;
ctx.wait_group.startMany(task_count);
for (0..task_count) |_| {
    // submit tasks to worker threads
    thread_pool.executor().submit(Ctx.run, .{&ctx}, allocator);
}
// Submitted task will eventually be executed by some worker thread.
// To wait for task completion, need to either synchronize manually
// by using WaitGroup etc. as below, or use higher-level primitives
// like Futures.
ctx.wait_group.wait();
assert(ctx.sum.load(.seq_cst) == task_count);
```


#### References:
- [example](/examples/threadPool.zig)
- [roadmap](https://github.com/zxubian/cozi/issues?q=is%3Aissue%20state%3Aopen%20label%3Afeature%20label%3A%22Thread%20Pool%22)
