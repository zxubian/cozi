# **cozi** - concurrency primitives for Zig
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

### Minimum Supported Zig Version

```
0.15.0-dev.670+1a08c83eb
```

### Steps

1. Install package:
```bash
zig fetch --save git+https://github.com/zxubian/cozi.git#main
```

2. Add `cozi` module to your executable:
```zig
// build.zig
const cozi = b.dependency("cozi", .{});
exe.root_module.addImport("cozi", cozi.module("root"));
```

3. Import  and use:
- [examples](examples/)

### Build Configuration Options
You can modify the behavior of `cozi` by overriding [build options](src/buildOptions.zig) at import timing.
1. For convenience, copy the [build scipt](buildScripts/cozi_build.zig) into your repository
2. Register the build options, and forward the results to `cozi` when registering it as a dependency:
```zig
//build.zig
const exe_mod = b.createModule(.{...});
// import cozi's build script
const cozi_build = @import("./cozi_build.zig");
// register cozi's build options & gather results
const cozi_build_options = cozi_build.parseBuildOptions(b);
// pass the parsed results to the cozi dependency
const cozi = b.dependency("cozi", cozi_build_options);
exe_mod.addImport("cozi", cozi.module("root"));
```
3. You can then check the list of available build options:
```bash
zig build -h
# > -Dcozi_log=[bool]            Enable verbose logging from inside the cozi library
# ...
```
For each option that is not overridden, `cozi` will use the default defined in [BuildOptions](src/buildOptions.zig).

### Stability Guarantees
`cozi` is experimental and unstable. Expect `main` branch to occasionally break.

## [Examples](examples/)

```bash
# get list of available examples
zig build example-run
# build & run specific example
zig build example-run -Dexample-name="some_example"
```
## Docs
```bash
# build documentation
zig build docs
# host docs on local http server
python3 -m http.server 8000 -d ./zig-out/docs
# open in browser
http://localhost:8000/index.html
```

## Features & Roadmap

### [Executors & Schedulers](src/executors)
- `Executor` is a type-erased interface representing an abstract task queue:
    - users can submit [Runnable](src/core/runnable.zig)s (an abstract representation of a task) for eventual execution
- `cozi`'s concurrency primitives (`Future`s, `Fiber`s) can run on any `Executor`
- `Executor` is to asynchronous task execution what [Allocator](https://github.com/ziglang/zig/blob/master/lib/std/mem/Allocator.zig) is to memory management.

```zig
const executor = thread_pool.executor();
executor.submit(some_function, .{args}, allocator);
// eventually, some_function(args) will be called.
// exact timing depends on the specific Executor implementation
```

### [Fibers](src/fiber) - stackfull cooperatively-scheduled user-space threads
- **threads**: like OS threads, fibers represents a "thread" of execution, i.e. an independent sequence of instructions together with its execution context (stack space)
- **stackful**: user must allocate memory for each fiber's execution stack (in contrast to e.g. stackless coroutines)
- **cooperatively-scheduled**: fibers are not pre-empted by the system or the `cozi` runtime
     - Instead, each fiber itself is responsible for releasing control of the underlying thread and allow other fibers to run
     - When in this state, the fiber is refered to as being _suspended_ or _parked_.

#### Comparison to other languages
- Fibers are an example of [Green Threads](https://en.wikipedia.org/wiki/Green_thread)
- Fibers are similar to [goroutines](https://go.dev/tour/concurrency/1) in GoLang, and [coroutines](https://kotlinlang.org/docs/coroutines-guide.html) in Kotlin

#### Supported Platforms
See [Coroutine - Supported Platforms](#coroutine---supported-platforms)

```zig
const Ctx = struct {
    sum: usize,
    wait_group: std.Thread.WaitGroup = .{},
    // non-blocking mutex for fibers
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
### Futures & Promises
- [source](src/future/lazy/root.zig)
> [!NOTE]  
> documentation WIP

### Stackfull Coroutine - a function you can suspend & resume
- [example](examples/coroutine.zig)
- [source](src/coroutine/root.zig)
- [roadmap](https://github.com/zxubian/cozi/issues?q=is%3Aissue%20state%3Aopen%20label%3ACoroutine%20label%3Afeature)

#### Coroutine - Supported Platforms

See [issue](https://github.com/zxubian/cozi/issues/8).

| Arch\OS | MacOS | Windows | Linux |
|:-------:|:-----:|:-------:|:-----:|
| aarch64 | ✅     | ❌       | ❌     |
| x86_64  | ❌     | ✅       | ❌     |

```zig
const cozi = @import("cozi");
const Coroutine = cozi.Coroutine;
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

### Long-term initiatives
#### integration with Zig async/await
  - It is currently unclear what direction Zig will go with for language support of async/await. 
  - Once the Zig Language direction is decided, we will consider the best way to integrate it with the library.

## Memory Management Policy:
  - API must allow fine-grained control over allocations for users who care
  - it's nice to provide "managed" API for users who don't (e.g. for testing)
  - regardless of memory management approach chosen by the user, library must minimize number of runtime allocations

# Acknowledgements
The design of **cozi** is heavily based on prior work, especially the [concurrency course](https://www.youtube.com/watch?v=zw6V3SDsXDk&list=PL4_hYwCyhAva37lNnoMuBcKRELso5nvBm) taught by [Roman Lipovsky](https://gitlab.com/Lipovsky) at MIPT.
The author would like to express his deepest gratitude to Roman for all of the knowledge that he shares publicly, and for his dedication to education in technology.
This library began as a fun exercise to go along with the course, and would not exist without it.

**Honourable mentions:**
- [YACLib](https://github.com/YACLib/YACLib)
- GoLang
    - [select](https://github.com/golang/go/blob/master/src/runtime/select.go)
- Rust
    - [zero-cost futures](https://aturon.github.io/tech/2016/09/07/futures-design/)
