//! Generators for futures.
//! All future pipelines will start with one of these.
pub const constValue = @import("./constValue.zig");
pub const contract = @import("./contract.zig");
pub const just = @import("./just.zig");
pub const value = @import("./value.zig");
pub const submit = @import("./submit.zig");
