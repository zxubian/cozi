const std = @import("std");
const log = std.log.scoped(.thread_pool);
const ThreadPool = @This();
const Thread = std.Thread;
const Queue = @import("./Queue.zig").UnboundedBlockingQueue;
const builtin = @import("builtin");

threads: []Thread = undefined,
tasks: Queue(Runnable) = undefined,
waitgroup: Thread.WaitGroup = .{},
allocator: std.mem.Allocator,

threadlocal var current: *ThreadPool = undefined;

pub const Runnable = struct {
    runFn: RunProto,
    pub const RunProto = *const fn () void;
};

pub const Executor = struct {
    submitFn: SubmitProto,
    pub const SubmitProto = *const fn (ctx: *Executor, task: Runnable) void;
};

pub fn init(thread_count: usize, allocator: std.mem.Allocator) !ThreadPool {
    const threads = try allocator.alloc(Thread, thread_count);
    const queue = Queue(Runnable){ .allocator = allocator };
    return ThreadPool{
        .threads = threads,
        .allocator = allocator,
        .tasks = queue,
    };
}

pub fn start(self: *ThreadPool, allocator: std.mem.Allocator) !void {
    for (self.threads) |*thread| {
        thread.* = try Thread.spawn(
            .{ .allocator = allocator },
            threadEntryPoint,
            .{self},
        );
    }
}

fn getCurrent() *const ThreadPool {
    return current;
}

fn threadEntryPoint(thread_pool: *ThreadPool) void {
    current = thread_pool;
    while (true) {
        const next_task = thread_pool.tasks.takeBlocking();
        next_task.runFn();
        thread_pool.waitgroup.finish();
    }
}

pub fn submit(self: *ThreadPool, task: Runnable) !void {
    try self.tasks.put(task);
    self.waitgroup.start();
}

pub fn waitIdle(self: *ThreadPool) void {
    self.waitgroup.wait();
}

pub fn deinit(self: *ThreadPool) void {
    self.tasks.deinit();
    self.allocator.free(self.threads);
}

fn printMessage(comptime message: []const u8) void {
    std.debug.print("{s}\n", .{message});
}

test "Thread Pool Unit Test" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }
    var tp = try ThreadPool.init(1, std.testing.allocator);
    try tp.submit(
        .{
            .runFn = struct {
                pub fn run() void {
                    printMessage("task 1");
                }
            }.run,
        },
    );
    try tp.start(std.testing.allocator);
    try tp.submit(
        .{
            .runFn = struct {
                pub fn run() void {
                    printMessage("task 2");
                }
            }.run,
        },
    );
    tp.waitIdle();
    tp.deinit();
}
