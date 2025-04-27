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
//! );
//! //...
//! const cozi = b.dependency("cozi", .{
//!    .fault_variant = fault_variant orelse {},
//! //...
//! });
//! ```
pub const BuildOptions = struct {
    fault_variant: fault.Variant = .none,
    sanitizer_variant: sanitizer.Variant = .none,
    log: bool = false,

    pub const fault = struct {
        pub const Variant = enum {
            none,
            thread_sleep,
            thread_yield,
            fiber,
        };
    };

    pub const sanitizer = struct {
        pub const Variant = enum {
            none,
            address,
            thread,
        };
    };
};

pub const options: BuildOptions = blk: {
    // init with default values
    var result: BuildOptions = .{};
    for (std.meta.fields(BuildOptions)) |field| {
        switch (@typeInfo(field.type)) {
            .@"enum" => {
                if (@hasField(impl_, field.name)) {
                    @field(result, field.name) = @enumFromInt(@intFromEnum(@field(impl_, field.name)));
                }
            },
            .bool => {
                if (@hasDecl(impl_, field.name)) {
                    @field(result, field.name) = @field(impl_, field.name);
                }
            },
            else => @compileError(
                std.fmt.comptimePrint(
                    "TODO: unsupported BuildOption field type `{}` for field `{s}`",
                    .{ field.type, field.name },
                ),
            ),
        }
    }
    break :blk result;
};

const std = @import("std");
const impl_ = @import("cozi_build_options");
