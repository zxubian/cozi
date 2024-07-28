const std = @import("std");
const log = std.log.scoped(.thread_pool);
const ThreadPool = @This();
const Thread = std.Thread;
const Queue = @import("./threadPool/queue.zig").UnboundedBlockingQueue;
const builtin = @import("builtin");
const assert = std.debug.assert;
const atomic = std.atomic.Value;

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

threadlocal var current: *ThreadPool = undefined;

pub const Runnable = struct {
    runFn: RunProto,
    pub const RunProto = *const fn (runnable: *Runnable) void;
};

pub const Executor = struct {
    submitFn: SubmitProto,
    pub const SubmitProto = *const fn (ctx: *Executor, task: Runnable) void;
};

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

pub fn submit(self: *ThreadPool, comptime func: anytype, args: anytype) !void {
    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *ThreadPool,
        runnable: Runnable,

        fn runFn(runnable: *Runnable) void {
            const closure: *@This() = @fieldParentPtr("runnable", runnable);
            @call(.auto, func, closure.arguments);

            // save the pointer to the pool so we can keep using it
            // even after closure is destroyed
            const pool = closure.pool;
            pool.mutex.lock();
            defer pool.mutex.unlock();

            // The thread pool's allocator is protected by the mutex.
            pool.allocator.destroy(closure);
        }
    };

    {
        if (self.status.load(.seq_cst) == .stopped) {
            return SubmitError.thread_pool_stopped;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const closure = try self.allocator.create(Closure);
        closure.* = .{
            .arguments = args,
            .pool = self,
            .runnable = .{
                .runFn = Closure.runFn,
            },
        };

        self.waitgroup.start();
        try self.tasks.put(&closure.runnable);
    }
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
