//! Compute thread pool, suitable for small number of independent tasks.
//! For fiber workloads, consider using work-stealing thread pool.
const std = @import("std");
const SystemThread = std.Thread;
const builtin = @import("builtin");
const assert = std.debug.assert;

const cozi = @import("../../root.zig");
const log = cozi.core.log.scoped(.thread_pool);
const fault = cozi.fault;
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const Allocator = std.mem.Allocator;
const Worker = cozi.await.Worker;

const Core = @import("../../core/root.zig");
const Runnable = Core.Runnable;
const Executor = @import("../../executors/root.zig").Executor;

const Queue = @import("./compute/queue.zig").UnboundedBlockingQueue;

const ThreadPool = @This();

const Status = enum(u8) {
    uninitialized,
    not_started,
    running_or_idle,
    // No new tasks may be submitted. Already submitted tasks will run to completion.
    stopped,
};

// for internal storage
threads: []SystemThread,
/// used to allocate the Threads. No allocations happen on runnable submit
gpa: ?Allocator = null,
tasks: Queue(Runnable) = .{},
status: Atomic(Status) = .init(.uninitialized),
finish_init_barrier: SystemThread.ResetEvent = .{},
thread_start_barrier: SystemThread.WaitGroup = .{},
init_options: Options,

threadlocal var current_: ?*ThreadPool = null;

pub const Options = struct {
    stack_size: u64 = std.Thread.SpawnConfig.default_stack_size,
    stack_allocator: Allocator,
};

/// Initialize the thread pool with default options.
/// NOTE: internally, this will spawn system threads,
/// initialize them as necessary, and pause them just
/// before entering the main event loop.
pub fn init(
    self: *ThreadPool,
    thread_count: usize,
    gpa: Allocator,
) !void {
    try self.initOptions(
        thread_count,
        gpa,
        .{
            .stack_allocator = gpa,
        },
    );
}

/// Initialize the thread pool with explicit options.
/// NOTE: internally, this will spawn system threads,
/// initialize them as necessary, and pause them just
/// before entering the main event loop.
pub fn initOptions(
    self: *@This(),
    thread_count: usize,
    gpa: Allocator,
    options: Options,
) !void {
    assert(thread_count > 0);
    const threads = try gpa.alloc(SystemThread, thread_count);
    self.* = ThreadPool{
        .threads = threads,
        .gpa = gpa,
        .init_options = options,
    };
    try self.initInternal();
}

/// Initialize the thread pool with explicit options.
/// NOTE: internally, this will spawn system threads,
/// initialize them as necessary, and pause them just
/// before entering the main event loop.
/// TODO: misleading name. allocation is still required for system thread stacks.
pub fn initNoAlloc(
    self: *@This(),
    threads: []SystemThread,
    options: Options,
) !void {
    self.* = .{
        .threads = threads,
        .gpa = null,
        .init_options = options,
    };
    try self.initInternal();
}

fn initInternal(self: *@This()) !void {
    if (self.status.cmpxchgStrong(
        .uninitialized,
        .not_started,
        .seq_cst,
        .seq_cst,
    )) |_| {
        unreachable;
    }
    self.thread_start_barrier.startMany(self.threads.len);
    for (self.threads, 0..) |*thread, i| {
        thread.* = try SystemThread.spawn(
            .{ .allocator = self.gpa },
            threadEntryPoint,
            .{
                self,
                i,
                thread,
            },
        );
    }
    self.thread_start_barrier.wait();
}

/// Wakes up worker threads.
/// Workers will proceed to enter the main event loop,
/// executing tasks from the queue one-by-one.
pub fn start(self: *ThreadPool) void {
    if (self.status.cmpxchgStrong(
        .not_started,
        .running_or_idle,
        .seq_cst,
        .seq_cst,
    )) |_| {
        unreachable;
    }
    self.finish_init_barrier.set();
}

pub fn current() ?*ThreadPool {
    return current_;
}

fn threadEntryPoint(
    thread_pool: *ThreadPool,
    i: usize,
    self: *SystemThread,
) void {
    thread_pool.thread_start_barrier.finish();
    thread_pool.finish_init_barrier.wait();
    current_ = thread_pool;

    assert(current_.?.status.load(.seq_cst) != .not_started);
    var thread_pool_name_buf: [std.Thread.max_name_len:0]u8 = undefined;
    const name = std.fmt.bufPrintZ(
        &thread_pool_name_buf,
        "Pool@{}/Thread #{}",
        .{ @intFromPtr(thread_pool), i },
    ) catch "Thread Pool@(unknown) Thread#(unknown)";
    const worker = Worker.Thread.init(self, &thread_pool_name_buf) catch |e| {
        std.debug.panic("Failed to initialize worker for threadpool thread {s}: {}", .{
            name,
            e,
        });
    };

    const previous = Worker.beginScope(worker);
    defer Worker.endScope(previous);

    while (true) {
        const current_status = current_.?.status.load(.seq_cst);
        switch (current_status) {
            .running_or_idle, .stopped => {
                const next_task = current_.?.tasks.takeBlocking() catch {
                    break;
                };
                log.debug("{s} acquired a new task: {}", .{ name, next_task.runFn });
                next_task.run();
            },
            .not_started, .uninitialized => unreachable,
        }
    }
    assert(current_.?.status.load(.seq_cst) == .stopped);
    log.debug("{s} exiting", .{name});
}

const SubmitError = error{
    thread_pool_stopped,
};

fn submitImpl(self: *ThreadPool, runnable: *Runnable) !void {
    if (self.status.load(.seq_cst) == .stopped) {
        return SubmitError.thread_pool_stopped;
    }
    try self.tasks.put(runnable);
}

pub fn submit(ctx: *anyopaque, runnable: *Runnable) void {
    var self: *ThreadPool = @alignCast(@ptrCast(ctx));
    log.debug("{*} got new task submission:{}", .{ self, runnable.runFn });
    self.submitImpl(runnable) catch |e| {
        log.err("{}", .{e});
    };
}

pub fn executor(self: *ThreadPool) Executor {
    return Executor{
        .vtable = .{
            .submit = ThreadPool.submit,
        },
        .ptr = @ptrCast(self),
    };
}

/// Closes the queue. Addition task submissions will fail.
/// Tasks submitted before stop() was called will be executed
/// before stop() returns.
/// Invariants after stop() returns:
/// - task queue is empty and closed
/// - worker threads have stopped execution
pub fn stop(self: *ThreadPool) void {
    assert(self.status.load(.seq_cst) == .running_or_idle);
    self.status.store(.stopped, .seq_cst);
    self.tasks.close();
    for (self.threads) |thread| {
        thread.join();
    }
}

/// Frees all memory associated with the thread pool
pub fn deinit(self: *ThreadPool) void {
    assert(self.status.load(.seq_cst) == .stopped);
    self.status.store(undefined, .seq_cst);
    self.tasks.deinit();
    if (self.gpa) |gpa_| {
        gpa_.free(self.threads);
    }
    self.* = undefined;
}

test {
    _ = @import("./compute/tests.zig");
}
