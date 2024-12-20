const std = @import("std");
const AtomicEnum = @import("./atomic_enum.zig");
const Fiber = @import("./fiber.zig");
const Strand = Fiber.Strand;
const Executors = @import("./executors.zig");
const ManualExecutor = Executors.Manual;
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var fiber_name: [Fiber.MAX_FIBER_NAME_LENGTH_BYTES:0]u8 = undefined;

    var strand: Strand = .{};
    var manual_executor = ManualExecutor{};
    const count: usize = 1;
    const Ctx = struct {
        strand: *Strand,
        counter: usize,

        pub fn run(self: *@This()) void {
            for (0..count) |_| {
                self.strand.combine(criticalSection, .{self});
            }
        }

        pub fn criticalSection(self: *@This()) void {
            Fiber.yield();
            assert(
                std.mem.eql(
                    u8,
                    "Fiber #0",
                    Fiber.current().?.name,
                ),
            );
            self.counter += 1;
        }
    };
    var ctx: Ctx = .{
        .strand = &strand,
        .counter = 0,
    };
    const fiber_count = 2;
    for (0..fiber_count) |i| {
        const name = try std.fmt.bufPrintZ(fiber_name[0..], "Fiber #{}", .{i});
        try Fiber.goOptions(
            Ctx.run,
            .{&ctx},
            allocator,
            manual_executor.executor(),
            .{
                .name = name,
            },
        );
    }
    _ = manual_executor.drain();
    assert(ctx.counter == count * fiber_count);
}

test {
    _ = @import("./tests.zig");
}
