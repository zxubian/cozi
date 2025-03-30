//! Generators for futures.
//! All future pipelines will start with one of these.
pub const submit = @import("./submit.zig").submit;
pub const just = @import("./just.zig");
pub const value = @import("./value.zig").value;
