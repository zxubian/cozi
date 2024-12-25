const std = @import("std");
const SanitizerOption = @import("./src/sanitizerOption.zig").SanitizerOption;

fn addAssemblyForMachineContext(b: *std.Build, c: *std.Build.Step.Compile, target: *const std.Build.ResolvedTarget) void {
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
    c.addAssemblyFile(path);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(SanitizerOption, "sanitize", "Whether to use ASan, TSan, or neither") orelse SanitizerOption.none;

    const exe = b.addExecutable(.{
        .name = "zig-async",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize == .thread,
        .use_llvm = true,
    });

    addAssemblyForMachineContext(b, exe, &target);

    const options = b.addOptions();

    options.addOption(SanitizerOption, "sanitize", sanitize);
    exe.root_module.addOptions("build_config", options);

    switch (sanitize) {
        .address => {
            exe.linkLibCpp();
            exe.pie = true;
        },
        .thread => {
            exe.linkLibCpp();
            exe.pie = true;
        },
        else => {},
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_filter_option = b.option([]const []const u8, "test-filter", "Test filter");

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .filters = if (test_filter_option) |o| o else &.{},
    });

    const install_test_step =
        b.addInstallArtifact(exe_unit_tests, .{ .dest_dir = .{ .override = .{ .custom = "test" } } });

    addAssemblyForMachineContext(b, exe_unit_tests, &target);

    exe_unit_tests.root_module.addOptions("build_config", options);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&install_test_step.step);
}
