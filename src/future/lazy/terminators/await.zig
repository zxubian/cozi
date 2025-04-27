const std = @import("std");

const cozi = @import("../../../root.zig");

const Fiber = cozi.Fiber;
const Awaiter = Fiber.@"await".Awaiter;
const Runnable = cozi.core.Runnable;
const atomic = cozi.fault.stdlike.atomic;
const SpinLock = cozi.sync.Spinlock;
const future = cozi.future.lazy;

const Await = @This();

pub fn Awaitable(Future: type) type {
    return struct {
        future: Future,
        input_computation: InputComputation = undefined,
        fiber: *Fiber = undefined,
        lock: SpinLock = .{},

        const InputComputation = Future.Computation(Demand);
        const Impl = @This();

        // --- awaitable implementation ---
        pub fn awaitReady(_: *@This()) bool {
            return false;
        }

        pub fn awaitResume(self: *@This(), _: bool) Future.ValueType {
            return self.input_computation.next.value;
        }

        pub fn awaiter(self: *@This()) Awaiter {
            return Awaiter{
                .ptr = self,
                .vtable = .{ .await_suspend = @ptrCast(&awaitSuspend) },
            };
        }

        pub fn awaitSuspend(
            self: *@This(),
            handle: *Fiber,
        ) Awaiter.AwaitSuspendResult {
            self.fiber = handle;
            self.input_computation = self.future.materialize(Demand{});
            self.input_computation.start();
            switch (@as(
                Demand.State,
                @enumFromInt(
                    self.input_computation.next.rendezvous.fetchOr(
                        @intFromEnum(
                            Demand.State.fiber_arrived,
                        ),
                        .seq_cst,
                    ),
                ),
            )) {
                .init => {
                    // fiber arrived first, future was not ready
                    // fiber will suspend
                    return .always_suspend;
                },
                .future_arrived => {
                    return .never_suspend;
                },
                else => std.debug.panic("Fiber arrived at rendezvous twice", .{}),
            }
        }

        fn onContinue(continuation: *Demand) void {
            const input_computation: *InputComputation = @fieldParentPtr(
                "next",
                continuation,
            );
            const self: *Impl = @fieldParentPtr(
                "input_computation",
                input_computation,
            );
            switch (@as(
                Demand.State,
                @enumFromInt(
                    continuation.rendezvous.fetchOr(
                        @intFromEnum(Demand.State.future_arrived),
                        .seq_cst,
                    ),
                ),
            )) {
                .fiber_arrived => {
                    // fiber arrived first and was suspended
                    self.fiber.scheduleSelf();
                },
                .init => {
                    // arrived before fiber, no need to do anything
                },
                else => std.debug.panic("Future arrived at rendezvous twice", .{}),
            }
        }

        const Demand = struct {
            runnable: Runnable = undefined,
            value: Future.ValueType = undefined,
            rendezvous: std.atomic.Value(u8) = .init(@intFromEnum(State.init)),

            pub const State = enum(u8) {
                init = 0,
                fiber_arrived = 1 << 0,
                future_arrived = 1 << 1,
                rendezvous = 3,
            };

            pub fn @"continue"(
                self: *@This(),
                value: Future.ValueType,
                state: future.State,
            ) void {
                self.value = value;
                self.runnable = .{
                    .runFn = @ptrCast(&onContinue),
                    .ptr = self,
                };
                state.executor.submitRunnable(&self.runnable);
            }
        };
    };
}
