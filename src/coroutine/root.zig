//! Stackfull coroutine
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cozi = @import("../root.zig");
const log = cozi.core.log.scoped(.coroutine);

const core = cozi.core;
const Runnable = core.Runnable;
const Closure = core.Closure;
const ExecutionContext = @import("./executionContext.zig");
const Trampoline = ExecutionContext.Trampoline;

pub const Stack = core.Stack;

const Coroutine = @This();

runnable: *Runnable = undefined,
stack: Stack = undefined,
previous_context: ExecutionContext = .{},
execution_context: ExecutionContext = .{},
is_completed: bool = false,

pub fn init(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    gpa: Allocator,
) !Managed {
    return try initOptions(routine, args, gpa, .{});
}

pub const Options = struct {
    stack_size: usize = Stack.DEFAULT_SIZE_BYTES,
};

pub fn initOptions(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    /// only used for allocating stack
    gpa: Allocator,
    options: Options,
) !Managed {
    const stack = try Stack.Managed.initOptions(gpa, .{ .size = options.stack_size });
    var fixed_buffer_allocator = stack.bufferAllocator();
    const stack_gpa = fixed_buffer_allocator.allocator();
    const self = try initOnStack(routine, args, stack, stack_gpa);
    return Managed{
        .coroutine = self,
        .stack = stack,
    };
}

pub fn initOnStack(
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    stack: Stack,
    stack_arena: Allocator,
) !*Coroutine {
    const self = try stack_arena.create(Coroutine);
    const routine_closure = try stack_arena.create(Closure(routine));
    routine_closure.init(args);
    self.initNoAlloc(
        &routine_closure.*.runnable,
        stack,
    );
    return self;
}

pub fn initWithStack(
    self: *Coroutine,
    comptime routine: anytype,
    args: std.meta.ArgsTuple(@TypeOf(routine)),
    stack: Stack,
    gpa: Allocator,
) !void {
    const routine_closure = try Closure(routine).Managed.init(
        args,
        gpa,
    );
    self.initNoAlloc(
        routine_closure.runnable(),
        stack,
    );
}

pub fn initNoAlloc(
    self: *Coroutine,
    runnable: *Runnable,
    stack: Stack,
) void {
    self.* = .{
        .runnable = runnable,
        .stack = stack,
    };
    self.execution_context.init(
        stack,
        self.trampoline(),
    );
}

fn trampoline(self: *Coroutine) Trampoline {
    return Trampoline{
        .ptr = self,
        .vtable = &.{
            .run = run,
        },
    };
}

fn run(ctx: *anyopaque) noreturn {
    var self: *Coroutine = @ptrCast(@alignCast(ctx));
    self.runnable.run();
    self.complete();
}

fn complete(self: *Coroutine) noreturn {
    self.is_completed = true;
    self.execution_context.exitTo(&self.previous_context);
}

pub fn @"resume"(self: *Coroutine) void {
    self.previous_context.switchTo(&self.execution_context);
}

pub fn @"suspend"(self: *Coroutine) void {
    self.execution_context.switchTo(&self.previous_context);
}

/// Returns true if current stack pointer belongs to
/// the address range of this Coroutine's Stack.
pub fn isInScope(self: *const Coroutine) bool {
    var a: usize = undefined;
    const addr = @intFromPtr(&a);
    const base = @intFromPtr(self.stack.base());
    const top = @intFromPtr(self.stack.top());
    const result = base <= addr and addr < top;
    log.debug(
        "rsp: 0x{x:0>8}. Coroutine stack address range [0x{x:0>8}, 0x{x:0>8}]. Is in range: {}",
        .{
            addr,
            base,
            top,
            result,
        },
    );
    return result;
}

pub const Managed = struct {
    coroutine: Coroutine,
    stack: Stack.Managed,

    pub fn initInPlace(
        self: *@This(),
        comptime routine: anytype,
        args: std.meta.ArgsTuple(@TypeOf(routine)),
        gpa: Allocator,
    ) !void {
        self.stack = try Stack.Managed.init(gpa);
        // TODO: use initOnStack here
        try self.coroutine.initWithStack(routine, args, self.stack.raw, gpa);
    }

    pub fn deinit(self: *@This()) void {
        assert(!self.coroutine.isInScope());
        self.stack.deinit();
    }

    pub inline fn @"resume"(self: *Managed) void {
        self.coroutine.@"resume"();
    }

    pub inline fn @"suspend"(self: *Managed) void {
        self.coroutine.@"suspend"();
    }

    pub inline fn isCompleted(self: *const Managed) bool {
        return self.coroutine.is_completed;
    }

    pub inline fn isInScope(self: *const Managed) bool {
        return self.coroutine.isInScope();
    }
};

test {
    _ = @import("./tests.zig");
}
