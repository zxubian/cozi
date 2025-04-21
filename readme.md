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
- [example](example/main.zig)

### Stability Guarantees
`zinc` is experimental and unstable. Expect `main` branch to occasionally break.

## Features & Roadmap

### Executors & Schedulers

#### Thread Pool
```zig
const zinc = @import("zinc");
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

#### Executor
Thread pool
  - [x] "Compute" - single global queue
    - [ ] Use lock-free queue
  - [ ] "Fast" - similar to GoLang: per-thread local queues, work-stealing
  - Optimizations:
  - [ ] Option to "pin" thread pool worker threads to CPU core (core affinity)
- [ ] Fiber pool
  - reference: [Parallelizing the Naughty Dog Engine Using Fibers](https://www.youtube.com/watch?v=HIVBhKj7gQU&t=628s)
  - [ ] Worker abstraction over fibers and threads?
     
Other considerations:
- [ ] Separate "scheduler" from "executor"? (scheduler responsible for picking next task out of queue(s), executor actually runs it)
- [ ] Scheduler "submit" hints (inline/lifo/queue-end etc)
- [ ] Pass context with nursery etc. to all tasks submitted to executor/scheduler -> for structured concurrency 

### Fibers - stackfull cooperatively-scheduled user-space threads
- [x] Basic support
- [x] Yield

Synchronization primitives
  - [x] Mutex
  - [x] Event
  - [x] Wait Group
  - [x] Barrier 

Channel
- https://github.com/zxubian/zig-async/issues/2

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
- [ ] lazy
- [ ] eager ? (consider if this should be removed & only "lazy" should be kept)


### Structured Concurrency
- [ ] cancellation token/source
- [ ] nursery?

### Testing
- [x] basic random fault injection for unit tests
- [ ] study [Twist](https://gitlab.com/Lipovsky/twist)

### Core
- [x] spin lock
- [x] intrusive foward list/queue/stack (not thread-safe)
- [ ] [Michael & Scott lock-free queue](https://dl.acm.org/doi/pdf/10.1145/248052.248106)
- [ ] hazard pointers

### Performance
- [ ] integrate with Tracy etc.
- [ ] optimize memory orders

### IO
- [ ] Play around with self-hosted IO dispatch
- [ ] Consider integration with [libxev](https://github.com/mitchellh/libxev)

### Long-term initiatives
- [ ] integration with Zig async/await
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
