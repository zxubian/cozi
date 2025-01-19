const std = @import("std");
const SanitizerOption = @import("./src/sanitizerOption.zig").SanitizerOption;

fn addAssemblyForMachineContext(
    b: *std.Build,
    dest: anytype,
    target: *const std.Build.ResolvedTarget,
) void {
    const path = switch (target.result.cpu.arch) {
        .aarch64 => b.path("./src/coroutine/context/machine/aarch64.s"),
        else => std.debug.panic(
            "Target architecture {s}-{s} is not yet supported",
            .{
                @tagName(target.result.os.tag),
                @tagName(target.result.cpu.arch),
            },
        ),
    };
    dest.addAssemblyFile(path);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(
        SanitizerOption,
        "sanitize",
        "Whether to use ASan, TSan, or neither",
    ) orelse SanitizerOption.none;

    const sanitize_thread = sanitize == .thread;
    const link_libcpp = sanitize != .none;

    const root = b.addModule("root", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libcpp = link_libcpp,
    });

    addAssemblyForMachineContext(b, root, &target);

    const options = b.addOptions();

    options.addOption(SanitizerOption, "sanitize", sanitize);
    root.addOptions("build_config", options);

    const test_filter_option = b.option([]const []const u8, "test-filter", "Test filter");
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = if (test_filter_option) |o| o else &.{},
        .sanitize_thread = sanitize == .thread,
    });

    switch (sanitize) {
        .address => {
            unit_tests.linkLibCpp();
            unit_tests.pie = true;
        },
        .thread => {
            unit_tests.linkLibCpp();
            unit_tests.pie = true;
        },
        else => {},
    }

    const install_test_step = b.addInstallArtifact(
        unit_tests,
        .{ .dest_dir = .{ .override = .{ .custom = "test" } } },
    );

    addAssemblyForMachineContext(b, unit_tests, &target);

    unit_tests.root_module.addOptions("build_config", options);

    const run_exe_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&install_test_step.step);
}
