const std = @import("std");

const cozi = @import("../../../root.zig");

const Awaiter = cozi.await.Awaiter;
const Worker = cozi.await.Worker;
const Runnable = cozi.core.Runnable;
const atomic = cozi.fault.stdlike.atomic;
const SpinLock = cozi.sync.Spinlock;
const future = cozi.future.lazy;

const Await = @This();

pub fn Awaitable(Future: type) type {
    return struct {
        future: Future,
        input_computation: InputComputation = undefined,
        worker: Worker = undefined,
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
            handle: Worker,
        ) Awaiter.AwaitSuspendResult {
            self.worker = handle;
            self.future.materialize(
                Demand{},
                &self.input_computation,
            );
            self.input_computation.start();
            switch (@as(
                Demand.State,
                @enumFromInt(
                    self.input_computation.next.rendezvous.fetchOr(
                        @intFromEnum(
                            Demand.State.thread_arrived,
                        ),
                        .seq_cst,
                    ),
                ),
            )) {
                .init => {
                    // thread arrived first, future was not ready
                    // thread will suspend
                    return .always_suspend;
                },
                .future_arrived => {
                    return .never_suspend;
                },
                else => std.debug.panic("Thread arrived at rendezvous twice", .{}),
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
                .thread_arrived => {
                    // thread arrived first and was suspended
                    self.worker.@"resume"();
                },
                .init => {
                    // arrived before thread, no need to do anything
                },
                else => std.debug.panic("Thread arrived at rendezvous twice", .{}),
            }
        }

        const Demand = struct {
            runnable: Runnable = undefined,
            value: Future.ValueType = undefined,
            rendezvous: std.atomic.Value(u8) = .init(@intFromEnum(State.init)),

            pub const State = enum(u8) {
                init = 0,
                thread_arrived = 1 << 0,
                future_arrived = 1 << 1,
                rendezvous = 3,
            };

            pub fn @"continue"(
                self: *@This(),
                value: Future.ValueType,
                _: future.State,
            ) void {
                self.value = value;
                onContinue(self);
            }
        };
    };
}
