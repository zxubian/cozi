# Fibers - stackfull cooperatively-scheduled user-space threads
- **threads**: like OS threads, fibers represents a "thread" of execution, i.e. an independent sequence of instructions together with its execution context (stack space)
- **stackful**: user must allocate memory for each fiber's execution stack (in contrast to e.g. stackless coroutines)
- **cooperatively-scheduled**: fibers are not pre-empted by the system or the `cozi` runtime
     - Instead, each fiber itself is responsible for releasing control of the underlying thread and allow other fibers to run
     - When in this state, the fiber is refered to as being _suspended_ or _parked_.

## Comparison with other languages
- Fibers are an example of [Green Threads](https://en.wikipedia.org/wiki/Green_thread)
- Fibers are similar to [goroutines](https://go.dev/tour/concurrency/1) in GoLang, and [coroutines](https://kotlinlang.org/docs/coroutines-guide.html) in Kotlin

## Features
### Basic Usage
<details>

<summary>Example</summary>

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

// Run 4 fibers on executor
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
</details>

### [Non-blocking synchronization primitives for Fibers](src/fiber/sync)
All of the following synchronization primitives work like their Thread counterparts, but do not block the underlying Thread (neither through spinning nor using `futex`).
Instead, the executing Fiber is suspended, and rescheduled for execution when appropriate for the primitive.

| Zig stdlib (for Threads)                                                                | cozi (for Fibers)                         |
| --------------------------------------------------------------------------------------- | ----------------------------------------- |
| [Mutex](https://github.com/ziglang/zig/blob/master/lib/std/Thread/Mutex.zig)            | [Mutex](src/fiber/sync/mutex.zig)         |
| [ResetEvent](https://github.com/ziglang/zig/blob/master/lib/std/Thread/ResetEvent.zig)  | [Event](src/fiber/sync/event.zig)         |
| [WaitGroup](https://github.com/ziglang/zig/blob/master/lib/std/Thread/WaitGroup.zig)    | [WaitGroup](src/fiber/sync/waitGroup.zig) | 
| n/a                                                                                     | [Barrier](src/fiber/sync/barrier.zig)     |
| n/a                                                                                     | [Strand](src/fiber/sync/strand.zig)       |

### Channel & Select
- Go-like [channel](https://gobyexample.com/channels) & [select](https://gobyexample.com/select) are supported.
- [Example](/examples/fiber_channel_select.zig)
- [Source](channel/root)

<details>
  <summary>
    Example
  </summary>

```zig
const Channel = cozi.Fiber.Channel;
const select = cozi.Fiber.select;
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

