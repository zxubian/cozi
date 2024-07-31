const std = @import("std");
const log = std.log.scoped(.thread_pool);
const ThreadPool = @This();
const Thread = std.Thread;
const Queue = @import("./threadPool/queue.zig").UnboundedBlockingQueue;
const builtin = @import("builtin");
const assert = std.debug.assert;
const atomic = std.atomic.Value;
const Executors = @import("../executors.zig");
const Runnable = Executors.Runnable;
const Executor = Executors.Executor;

const Status = enum(u8) {
    not_started,
    running_or_idle,
    // No new tasks may be submitted. Already submitted tasks will run to completion.
    stopped,
};

threads: []Thread = undefined,
tasks: Queue(*Runnable) = undefined,
waitgroup: Thread.WaitGroup = .{},
allocator: std.mem.Allocator,
mutex: Thread.Mutex = .{},
status: atomic(Status) = undefined,
executor: Executor = .{
    .vtable = .{
        .submitFn = ThreadPool.submit,
    },
},

threadlocal var current: *ThreadPool = undefined;

pub fn init(thread_count: usize, allocator: std.mem.Allocator) !ThreadPool {
    const threads = try allocator.alloc(Thread, thread_count);
    const queue = Queue(*Runnable){ .allocator = allocator };
    return ThreadPool{
        .threads = threads,
        .allocator = allocator,
        .tasks = queue,
        .status = atomic(Status).init(.not_started),
    };
}

pub fn start(self: *ThreadPool) !void {
    assert(self.status.cmpxchgStrong(.not_started, .running_or_idle, .seq_cst, .seq_cst) == null);
    for (self.threads, 0..) |*thread, i| {
        thread.* = try Thread.spawn(
            .{ .allocator = self.allocator },
            threadEntryPoint,
            .{ self, i, thread },
        );
    }
}

fn getCurrent() *const ThreadPool {
    return current;
}

fn threadEntryPoint(thread_pool: *ThreadPool, i: usize, self: *const Thread) void {
    current = thread_pool;
    assert(current.status.load(.seq_cst) != .not_started);
    var thread_pool_name_buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&thread_pool_name_buf, "Thread Pool@{}/Thread #{}", .{ @intFromPtr(thread_pool), i }) catch "Thread Pool@(unknown) Thread#(unknown)";
    self.setName(name) catch {};
    while (true) {
        const current_status = current.status.load(.seq_cst);
        switch (current_status) {
            .running_or_idle, .stopped => {
                const next_task = current.tasks.takeBlocking() orelse {
                    break;
                };
                log.debug("{s} acquired a new task\n", .{name});
                next_task.runFn(next_task);
                thread_pool.waitgroup.finish();
            },
            .not_started => unreachable,
        }
    }
    log.debug("{s} exiting", .{name});
}

const SubmitError = error{
    thread_pool_stopped,
};

fn submit_internal(self: *ThreadPool, runnable: *Runnable) !void {
    if (self.status.load(.seq_cst) == .stopped) {
        return SubmitError.thread_pool_stopped;
    }
    self.waitgroup.start();
    try self.tasks.put(runnable);
}

pub fn submit(exec: *Executor, runnable: *Runnable) void {
    var self: *ThreadPool = @fieldParentPtr("executor", exec);

    self.submit_internal(runnable) catch |e| {
        log.err("{}", .{e});
    };
}

pub fn waitIdle(self: *ThreadPool) void {
    self.waitgroup.wait();
    self.waitgroup.reset();
}

pub fn stop(self: *ThreadPool) void {
    assert(self.status.load(.seq_cst) == .running_or_idle);
    self.status.store(.stopped, .seq_cst);
    self.tasks.close();
    for (self.threads) |thread| {
        thread.join();
    }
    self.waitgroup.reset();
}

pub fn deinit(self: *ThreadPool) void {
    assert(self.status.load(.seq_cst) == .stopped);
    self.status.store(undefined, .seq_cst);
    self.tasks.deinit();
    self.allocator.free(self.threads);
}

test {
    _ = @import("./threadPool/tests.zig");
}
