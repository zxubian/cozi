//! `cozi` build options
//! When using `cozi` as a module, you may provide values for
//! each of these options via your build script.
//!
//! # Example:
//! ```zig
//! //build.zig
//! const fault_variant: BuildOptions.fault.Variant = b.option(
//!     buildOptions.fault.Variant,
//!     "fault-inject",
//!     "Which variant of fault injection to use.",
//! ) orelse .default();
//! //...
//! const cozi = b.dependency("cozi", .{
//!    .fault_variant = fault_variant,
//! //...
//! });
//! ```

fault_variant: fault.Variant,
sanitizer_variant: sanitizer.Variant,

const BuildOptions = @This();

pub const fault = struct {
    pub const Variant = enum {
        none,
        thread_sleep,
        thread_yield,
        fiber,

        pub fn default() Variant {
            return .none;
        }
    };

    pub const variant: Variant = impl.fault_variant;
};

pub const sanitizer = struct {
    pub const Variant = enum {
        none,
        address,
        thread,

        pub fn default() Variant {
            return .none;
        }
    };

    pub const variant: Variant = impl.sanitizer_variant;
};

const impl: BuildOptions = blk: {
    var result: BuildOptions = undefined;
    for (std.meta.fields(BuildOptions)) |field| {
        @field(result, field.name) = getEnumFromBuildOptions(field.name, field.type);
    }
    break :blk result;
};

fn getEnumFromBuildOptions(
    option_name: []const u8,
    Enum: type,
) Enum {
    const impl_ = @import("cozi_build_options");
    if (std.meta.fieldIndex(impl_, option_name)) |_| {
        return @enumFromInt(@intFromEnum(@field(impl_, option_name)));
    }
    return .default();
}

const std = @import("std");
