const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(
        .{
            .name = "example",
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    const fault_inject_variant = b.option(
        []const u8,
        "fault_inject",
        "Which fault injection build type to use",
    );
    const zig_async = blk: {
        if (fault_inject_variant) |user_input| {
            break :blk b.dependency("zig_async", .{
                .fault_inject = user_input,
            });
        }
        break :blk b.dependency("zig_async", .{});
    };

    exe.root_module.addImport("zig-async", zig_async.module("root"));

    const install_cmd = b.addInstallArtifact(exe, .{});
    install_cmd.step.dependOn(&exe.step);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install_cmd.step);
    const run_step = b.step("run", "Build & runt the example");
    run_step.dependOn(&run_cmd.step);
}
