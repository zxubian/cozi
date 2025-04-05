//!Sequential & concurrent combinators for futures.
pub const via = @import("./via.zig");
pub const map = @import("./map.zig");
pub const mapOk = @import("./mapOk.zig");
pub const andThen = @import("./andThen.zig");
pub const orElse = @import("./orElse.zig");
