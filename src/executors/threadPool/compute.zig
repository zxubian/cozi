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
const Worker = cozi.@"await".Worker;

const Core = @import("../../core/root.zig");
const Runnable = Core.Runnable;
const Executor = @import("../../executors/root.zig").Executor;

const Queue = @import("./compute/queue.zig").UnboundedBlockingQueue;

const ThreadPool = @This();

const Status = enum(u8) {
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
status: Atomic(Status) = .init(.not_started),
finish_init_barrier: SystemThread.ResetEvent = .{},
thread_start_barrier: SystemThread.WaitGroup = .{},

threadlocal var current_: ?*ThreadPool = null;

pub fn init(thread_count: usize, gpa: Allocator) !ThreadPool {
    const threads = try gpa.alloc(SystemThread, thread_count);
    return ThreadPool{
        .threads = threads,
        .gpa = gpa,
    };
}

pub fn initNoAlloc(threads: []SystemThread) ThreadPool {
    return ThreadPool{
        .threads = threads,
    };
}

pub fn start(self: *ThreadPool) !void {
    assert(self.status.cmpxchgStrong(.not_started, .running_or_idle, .seq_cst, .seq_cst) == null);
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

    const previous = Worker.beginScope(Worker.Thread.worker(self));
    defer Worker.endScope(previous);

    assert(current_.?.status.load(.seq_cst) != .not_started);
    var thread_pool_name_buf: [std.Thread.max_name_len]u8 = undefined;
    const name = std.fmt.bufPrint(
        &thread_pool_name_buf,
        "Pool@{}/Thread #{}",
        .{ @intFromPtr(thread_pool), i },
    ) catch "Thread Pool@(unknown) Thread#(unknown)";
    self.setName(name) catch |e| {
        std.debug.panic("Failed to set thread name {s} for thread:{} {}", .{
            name,
            self.getHandle(),
            e,
        });
    };
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
            .not_started => unreachable,
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

pub fn stop(self: *ThreadPool) void {
    assert(self.status.load(.seq_cst) == .running_or_idle);
    self.status.store(.stopped, .seq_cst);
    self.tasks.close();
    for (self.threads) |thread| {
        thread.join();
    }
}

pub fn deinit(self: *ThreadPool) void {
    assert(self.status.load(.seq_cst) == .stopped);
    self.status.store(undefined, .seq_cst);
    self.tasks.deinit();
    if (self.gpa) |gpa_| {
        gpa_.free(self.threads);
    }
}

test {
    _ = @import("./compute/tests.zig");
}
