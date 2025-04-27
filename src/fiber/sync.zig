//! Non-blocking synchronization primitives for Fibers
//! All of the following synchronization primitives work
//! like their Thread counterparts, but do not block the underlying Thread.
//! Instead, the executing Fiber is suspended, and rescheduled
//! for execution when appropriate for the primitive.

pub const Barrier = @import("./sync/barrier.zig");
pub const Event = @import("./sync/event.zig");
pub const Mutex = @import("./sync/mutex.zig");
pub const Strand = @import("./sync/strand.zig");
pub const WaitGroup = @import("./sync/waitGroup.zig");

test {
    _ = @import("./sync/barrier.zig");
    _ = @import("./sync/event.zig");
    _ = @import("./sync/mutex.zig");
    _ = @import("./sync/strand.zig");
    _ = @import("./sync/waitGroup.zig");
}
