const std = @import("std");
const BuildOptions = @import("./src/buildOptions.zig").BuildOptions;

fn addAssemblyForMachineContext(
    b: *std.Build,
    dest: anytype,
    target: *const std.Build.ResolvedTarget,
) void {
    const path = switch (target.result.cpu.arch) {
        .aarch64 => b.path("./src/coroutine/context/machine/aarch64.s"),
        .x86_64 => switch (target.result.os.tag) {
            .windows => b.path("./src/coroutine/context/machine/x84_64_windows.s"),
            else => std.debug.panic(
                "Target architecture {s}-{s} is not yet supported",
                .{
                    @tagName(target.result.os.tag),
                    @tagName(target.result.cpu.arch),
                },
            ),
        },
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
    const FaultVariant = BuildOptions.fault.Variant;
    const SanitizerVariant = BuildOptions.sanitizer.Variant;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitizer_variant: ?SanitizerVariant = b.option(
        SanitizerVariant,
        "sanitizer_variant",
        "Whether to use ASan, TSan, or neither",
    );

    const fault_build_variant: ?FaultVariant = b.option(
        FaultVariant,
        "fault_variant",
        "Which variant of fault injection to use.",
    );

    const cozi_build_options = b.addOptions();
    if (fault_build_variant) |variant| {
        cozi_build_options.addOption(
            FaultVariant,
            "fault_variant",
            variant,
        );
    }
    if (sanitizer_variant) |variant| {
        cozi_build_options.addOption(
            SanitizerVariant,
            "sanitizer_variant",
            variant,
        );
    }
    if (b.option(
        bool,
        "log",
        "Enable verbose logging from inside the cozi library",
    )) |log| {
        cozi_build_options.addOption(
            bool,
            "log",
            log,
        );
    }

    const sanitize_thread = sanitizer_variant == .thread;
    const link_libcpp = sanitizer_variant != .none;

    const root = b.addModule("root", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libcpp = link_libcpp,
    });

    root.addOptions("cozi_build_options", cozi_build_options);

    addAssemblyForMachineContext(b, root, &target);

    const test_filter_option = b.option([]const []const u8, "test-filter", "Test filter");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitizer_variant == .thread,
        .link_libcpp = sanitizer_variant == .thread,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .filters = if (test_filter_option) |o| o else &.{},
    });

    if (sanitizer_variant) |variant| {
        switch (variant) {
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
    }

    const install_test_step = b.addInstallArtifact(
        unit_tests,
        .{
            .dest_dir = .{
                .override = .{
                    .custom = "test",
                },
            },
        },
    );

    addAssemblyForMachineContext(b, unit_tests, &target);

    unit_tests.root_module.addOptions(
        "cozi_build_options",
        cozi_build_options,
    );

    const run_exe_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step(
        "test",
        "Run unit tests",
    );

    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&install_test_step.step);

    const doc_test = b.addObject(.{
        .name = "cozi",
        .root_module = root,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Copy documentation artifacts to prefix path");
    docs_step.dependOn(&install_docs.step);

    const examples_step = b.step("examples", "Build & install all examples");
    buildExamples(
        b,
        Examples,
        examples_step,
        target,
        optimize,
        root,
    );
}

const Examples = @import("./examples/root.zig");

fn buildExamples(
    b: *std.Build,
    examples: type,
    example_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    cozi_root: *std.Build.Module,
) void {
    const Example = std.meta.DeclEnum(examples);
    const maybe_example_name = b.option(Example, "example-name", "Name of the example");
    const examples_decls = comptime std.meta.declarations(examples);
    const build_target_example = b.step("example", "Build specific example");
    const run_target_example = b.step("example-run", "Build and run specific example");

    inline for (examples_decls) |example_decl| {
        const example_name_string = example_decl.name;
        const example_name = std.meta.stringToEnum(Example, example_name_string);
        const exe_main = comptime @field(examples, example_name_string);

        const exe_mod = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&[_][]const u8{ "examples", exe_main })),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("cozi", cozi_root);

        const exe = b.addExecutable(
            .{
                .name = example_name_string,
                .root_module = exe_mod,
            },
        );

        const install_exe_step = b.addInstallArtifact(exe, .{});
        install_exe_step.step.dependOn(&exe.step);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(&install_exe_step.step);
        if (maybe_example_name) |target_example_name| {
            if (example_name == target_example_name) {
                build_target_example.dependOn(&install_exe_step.step);
                run_target_example.dependOn(&run_exe.step);
            }
        }
        example_step.dependOn(&install_exe_step.step);
    }

    if (maybe_example_name == null) {
        const examples_names = comptime blk: {
            const decls = std.meta.declarations(examples);
            var name: [:0]const u8 = "";
            for (decls, 0..) |decl, i| {
                name = name ++ "\"" ++ decl.name ++ "\"";
                if (i < decls.len - 1) {
                    name = name ++ " | ";
                }
            }
            break :blk name;
        };
        build_target_example.dependOn(&b.addFail(
            std.fmt.comptimePrint("Missing required argument: -Dexample-name={s}", .{examples_names}),
        ).step);
        run_target_example.dependOn(&b.addFail(
            std.fmt.comptimePrint("Missing required argument: -Dexample-name={s}", .{examples_names}),
        ).step);
    }
}
