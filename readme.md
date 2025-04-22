# **zinc** - concurrency primitives for Zig
_Fibers, thread pools, futures - all in userland Zig. Oh My!_

## Goals
- empower Zig users to solve concurrent & parallel engineering problems
  - at a higher level of expressiveness than basic synchronization primitives (mutex/condvar)
  - while maintaining the low-level control that is crucial for systems programming
- to that end, provide a toolbox of software components with the following properties:
  - orthogonal - components are meaningful and useful by themselves. Components have minimal coupling between themselves.
  - composable - components can be combined to produce more powerful behaviours.
  - extensible - we cannot anticipate every use-case. So, our APIs must be designed in a way that allows users of the library to integrate their custom solutions.

## Installation

### Zig Version

```
0.15.0-dev.337+4e700fdf8
```

### Steps

1. Install package:
```bash
zig fetch --save git+https://github.com/zxubian/zinc.git#main
```

2. Add `zinc` module to your executable:
```zig
// build.zig
    const fault_inject_variant = b.option(
        []const u8,
        "zinc_fault_inject",
        "Which fault injection build type to use",
    );
    const zinc = blk: {
        if (fault_inject_variant) |user_input| {
            break :blk b.dependency("zinc", .{
                .fault_inject = user_input,
            });
        }
        break :blk b.dependency("zinc", .{});
    };
    exe.root_module.addImport("zinc", zinc.module("root"));
```

3. Import `zinc` and use:
- [examples](examples/)

### Stability Guarantees
`zinc` is experimental and unstable. Expect `main` branch to occasionally break.

## Features & Roadmap

### Executors & Schedulers

#### [Executor](src/executors/executor.zig)
- `Executor` is a type-erased interface representing an abstract task queue.
- `Executor` allows users to submit [Runnable](src/core/runnable.zig)s (an abstract representation a task) for eventual execution.
    - Correct user programs cannot depend on the timing or order of execution of runnables, and cannot make assumptions about which thread will execute the runnable.
- `Executor` is to asynchronous task execution what [Allocator](https://github.com/ziglang/zig/blob/master/lib/std/mem/Allocator.zig) is to memory management.
- `Executor` is a fundamental building block, and many other primitives of `zinc` depend on it (e.g. both `Future` and `Fiber` can run on any `Executor`)

##### Available Executors:
###### [Inline](src/executors/inline.zig)
```zig
const inline_executor = zinc.executors.@"inline";
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
###### [Manual](src/executors/manual.zig)
-  Single-threaded manually-executed task queue
```zig
const ManualExecutor = zinc.executors.Manual;
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

###### [Thread Pool](src/executors/threadPool/compute.zig)
```zig
const ThreadPool = zinc.executors.threadPools.Compute;
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
#### Properties:
- intrusive linked list as basis for task queue (thread pool itself does not allocate on task `submit`)
- single tasks queue, shared between all worker threads
- customizable stack size for worker threads
#### References:
- [example](examples/threadPool.zig)
- [source](src/executors/threadPool/compute.zig)
- [roadmap](https://github.com/zxubian/zinc/issues?q=is%3Aissue%20state%3Aopen%20label%3Afeature%20label%3A%22Thread%20Pool%22)

### [Fibers](src/fiber/root.zig) - stackfull cooperatively-scheduled user-space threads
- **Stackful**: user must allocate memory for each fiber's execution stack
- **cooperatively-scheduled**: fibers are not pre-empted by the system or the `zinc` runtime
     - Instead, each fiber itself is responsible for releasing control of the underlying thread and allow other fibers to run
     - When this happens, the fiber's state is refered to as _suspened_ or _parked_.

```zig
const Ctx = struct {
    sum: usize,
    wait_group: std.Thread.WaitGroup = .{},
    mutex: Fiber.Mutex = .{},
    pub fn run(
        self: *@This(),
    ) void {
        for (0..10) |_| {
            {
                // Fibers running on thread pool may access
                // shared variable `sum` in parallel.
                // Fiber.Mutex provides mutual exclusion without
                // blocking underlying thread.
                self.mutex.lock();
                defer self.mutex.unlock();
                self.sum += 1;
            }
            // Suspend execution here (allowing for other fibers to be run),
            // and immediately reschedule self with the Executor.
            Fiber.yield();
        }
        self.wait_group.finish();
    }
};
var ctx: Ctx = .{ .sum = 0 };
const fiber_count = 4;
ctx.wait_group.startMany(fiber_count);

// Run 4 fibers on 2 threads
for (0..4) |fiber_id| {
    try Fiber.goWithNameFmt(
        Ctx.run,
        .{&ctx},
        allocator,
        executor,
        "Fiber #{}",
        .{fiber_id},
    );
}
// Synchronize Fibers running in a thread pool
// with the launching (main) thread.
ctx.wait_group.wait();
```

#### [Non-blocking synchronization primitives for Fibers](src/fiber/sync)
All of the following synchronization primitives work like their Thread counterparts, but do not block the underlying Thread (neither through spinning nor using `futex`).
Instead, the executing Fiber is suspended, and rescheduled for execution when appropriate for the primitive.

| Zig stdlib (for Threads)                                                                | zinc (for Fibers)                         |
| --------------------------------------------------------------------------------------- | ----------------------------------------- |
| [Mutex](https://github.com/ziglang/zig/blob/master/lib/std/Thread/Mutex.zig)            | [Mutex](src/fiber/sync/mutex.zig)         |
| [ResetEvent](https://github.com/ziglang/zig/blob/master/lib/std/Thread/ResetEvent.zig)  | [Event](src/fiber/sync/event.zig)         |
| [WaitGroup](https://github.com/ziglang/zig/blob/master/lib/std/Thread/WaitGroup.zig)    | [WaitGroup](src/fiber/sync/waitGroup.zig) | 
| n/a                                                                                     | [Barrier](src/fiber/sync/barrier.zig)     |
| n/a                                                                                     | [Strand](src/fiber/sync/strand.zig)       |

#### Channel & Select
- Go-like [channel](https://gobyexample.com/channels) & [select](https://gobyexample.com/select) are supported.

##### References
- [Example](examples/fiber_channel_select.zig)
- [Source]()

<details>
  <summary>
    Example
  </summary>

```zig
const Channel = zinc.Fiber.Channel;
const select = zinc.Fiber.select;
const Ctx = struct {
    channel_usize: Channel(usize) = .{},
    channel_string: Channel([]const u8) = .{},
    wait_group: std.Thread.WaitGroup = .{},

    pub fn sendString(ctx: *@This()) void {
        ctx.channel_string.send("456");
        ctx.wait_group.finish();
    }

    pub fn receiver(ctx: *@This()) void {
        switch (select(
            .{
                .{ .receive, &ctx.channel_usize },
                .{ .receive, &ctx.channel_string },
            },
        )) {
            .@"0" => |_| {
                unreachable;
            },
            .@"1" => |optional_result_string| {
                // null indicates that channel was closed
                if (optional_result_string) |result_string| {
                    assert(std.mem.eql(u8, "456", result_string));
                } else unreachable;
            },
        }
        ctx.wait_group.finish();
    }
};

var ctx: Ctx = .{};
ctx.wait_group.startMany(2);

try Fiber.go(
    Ctx.receiver,
    .{&ctx},
    allocator,
    executor,
);

try Fiber.go(
    Ctx.sendString,
    .{&ctx},
    allocator,
    executor,
);

// Synchronize Fibers running in a thread pool
// with the launching (main) thread.
ctx.wait_group.wait();
```
</details>

### Stackfull Coroutine - a function you can suspend & resume
- [example](examples/coroutine.zig)
- [source](src/coroutine/root.zig)
- [roadmap](https://github.com/zxubian/zinc/issues?q=is%3Aissue%20state%3Aopen%20label%3ACoroutine%20label%3Afeature)
```zig
const zinc = @import("zinc");
const Coroutine = zinc.Coroutine;
// ... 
const Ctx = struct {
    pub fn run(ctx: *Coroutine) void {
        log.debug("step 1", .{});
        ctx.@"suspend"();
        log.debug("step 2", .{});
        ctx.@"suspend"();
        log.debug("step 3", .{});
    }
};

var coro: Coroutine.Managed = undefined;
try coro.initInPlace(Ctx.run, .{&coro.coroutine}, gpa.allocator());
defer coro.deinit();
for (0..3) |_| {
    coro.@"resume"();
}
assert(coro.isCompleted());
```

### Futures & Promises
- [source](src/future/lazy/root.zig)
> [!NOTE]  
> documentation WIP


### Long-term initiatives
#### integration with Zig async/await
  - It is currently unclear what direction Zig will go with for language support of async/await. 
  - Once the Zig Language direction is decided, we will consider the best way to integrate it with the library.

## Memory Management Policy:
  - API must allow fine-grained control over allocations for users who care
  - it's nice to provide "managed" API for users who don't (e.g. for testing)
  - regardless of memory management approach chosen by the user, library must minimize number of runtime allocations

# Acknowledgements
The design of **zinc** is heavily based on prior work, especialy the [concurrency course](https://www.youtube.com/watch?v=zw6V3SDsXDk&list=PL4_hYwCyhAva37lNnoMuBcKRELso5nvBm) taught by [Roman Lipovsky](https://gitlab.com/Lipovsky) at MIPT. The author would like to express his deepest gratitude to Roman for all of the knowledge that he shares publicly, and for his dedication to education in technology. This library began as a fun exercise to go along with the course, and would not exist without it.

**Honourable mentions:**
- [YACLib](https://github.com/YACLib/YACLib)
- GoLang
    - [select](https://github.com/golang/go/blob/master/src/runtime/select.go)
- Rust
    - [zero-cost futures](https://aturon.github.io/tech/2016/09/07/futures-design/)
