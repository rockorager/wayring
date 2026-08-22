const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayring = b.addModule("wayring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scanner = b.addExecutable(.{
        .name = "wayring-scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wayring-scanner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wayring", .module = wayring }},
        }),
    });
    b.installArtifact(scanner);

    const tests = b.addTest(.{ .root_module = wayring });
    const run_tests = b.addRunArtifact(tests);

    const generate_test_protocol = b.addRunArtifact(scanner);
    generate_test_protocol.addFileArg(b.path("test/dependency.xml"));
    generate_test_protocol.addFileArg(b.path("test/protocol.xml"));
    const generated_test_protocol = generate_test_protocol.addOutputFileArg("wayring-test-protocol.zig");
    const generated_test_module = b.createModule(.{
        .root_source_file = generated_test_protocol,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const generated_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generated-codec.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "generated_protocol", .module = generated_test_module },
            },
        }),
    });
    const run_generated_tests = b.addRunArtifact(generated_tests);
    const client_core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/client-core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "generated_protocol", .module = generated_test_module },
            },
        }),
    });
    const run_client_core_tests = b.addRunArtifact(client_core_tests);
    const server_core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/server-core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "generated_protocol", .module = generated_test_module },
            },
        }),
    });
    const run_server_core_tests = b.addRunArtifact(server_core_tests);
    const end_to_end_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/end-to-end.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "generated_protocol", .module = generated_test_module },
            },
        }),
    });
    const run_end_to_end_tests = b.addRunArtifact(end_to_end_tests);
    const fuzz_optimize: std.builtin.OptimizeMode = if (optimize == .Debug)
        .ReleaseSafe
    else
        optimize;
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            // Zig 0.16's self-hosted Debug fuzz runner has incompatible
            // stack-trace types. ReleaseSafe uses the supported LLVM path.
            .optimize = fuzz_optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "generated_protocol", .module = generated_test_module },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_generated_tests.step);
    test_step.dependOn(&run_client_core_tests.step);
    test_step.dependOn(&run_server_core_tests.step);
    test_step.dependOn(&run_end_to_end_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);

    const fuzz_step = b.step("fuzz", "Fuzz wire and connection state machines");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    const soak_options = b.addOptions();
    soak_options.addOption(usize, "rounds", b.option(
        usize,
        "soak-rounds",
        "Number of randomized io_uring soak rounds",
    ) orelse 32);
    soak_options.addOption(u64, "seed", b.option(
        u64,
        "soak-seed",
        "PRNG seed for the io_uring soak test",
    ) orelse 0x7761_7972_696e_6701);
    const soak_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/io-uring-soak.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "soak_options", .module = soak_options.createModule() },
            },
        }),
    });
    const run_soak_tests = b.addRunArtifact(soak_tests);
    const soak_step = b.step("soak", "Run randomized real io_uring lifecycle tests");
    soak_step.dependOn(&run_soak_tests.step);

    const protocol_compat_test = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--build-file",
        "tools/upstream/build.zig",
        "--cache-dir",
        ".zig-cache/upstream",
        "protocol-compat",
    });
    const protocol_compat_step = b.step(
        "protocol-compat",
        "Generate and test pinned upstream Wayland protocols",
    );
    protocol_compat_step.dependOn(&protocol_compat_test.step);

    const build_benchmarks = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--build-file",
        "tools/upstream/build.zig",
        "--cache-dir",
        ".zig-cache/upstream",
        "benchmarks",
    });
    const benchmark_step = b.step("benchmarks", "Build the benchmark executables");
    benchmark_step.dependOn(&build_benchmarks.step);
}
