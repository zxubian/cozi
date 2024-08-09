const std = @import("std");
const SanitizerOption = @import("./src/sanitizerOption.zig").SanitizerOption;

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

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.root_module.addOptions("build_config", options);
    if (target.result.cpu.arch == .aarch64) {
        exe.addAssemblyFile(b.path("./src/coroutine/context/machine/aarch64.s"));
        exe_unit_tests.addAssemblyFile(b.path("./src/coroutine/context/machine/aarch64.s"));
    }

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
