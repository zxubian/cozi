//!Sequential & concurrent combinators for futures.
pub const via = @import("./via.zig");
pub const map = @import("./map.zig");
pub const mapOk = @import("./mapOk.zig");
pub const andThen = @import("./andThen.zig");
pub const orElse = @import("./orElse.zig");
pub const flatten = @import("./flatten.zig");
pub const all = @import("./all.zig");
pub const first = @import("./first.zig");
pub const box = @import("./box.zig");
