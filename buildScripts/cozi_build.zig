//! `cozi` build options
//! When using `cozi` as a module, you may provide values for
//! each of these options via your build script.
//!
//! # Example:
//! ```zig
//! //build.zig
//! const exe_mod = b.createModule(.{
//!     //...
//! });
//! const cozi_build = @import("./cozi_build.zig");
//! const cozi_build_options = cozi_build.parseBuildOptions(b);
//! const cozi = b.dependency("cozi", cozi_build_options);
//! exe_mod.addImport("cozi", cozi.module("root"));
//! });
//! ```
const std = @import("std");
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

    const Descriptions = struct {
        pub const fault_variant = "Which type of fault injection to use";
        pub const sanitizer_variant = "Which sanitizer to use";
        pub const log = "Enable verbose logging from inside the cozi library";
    };
};

pub fn parseBuildOptions(
    b: *std.Build,
) BuildOptions {
    var result: BuildOptions = .{};
    inline for (std.meta.fields(BuildOptions)) |field| {
        if (b.option(
            field.type,
            "cozi_" ++ field.name,
            @field(BuildOptions.Descriptions, field.name),
        )) |value| {
            @field(result, field.name) = value;
        }
    }
    return result;
}
