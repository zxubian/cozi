//! Generators for futures.
//! All future pipelines will start with one of these.
pub const submit = @import("./submit.zig");
pub const just = @import("./just.zig");
pub const value = @import("./value.zig");
pub const constValue = @import("./constValue.zig");
