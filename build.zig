const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wayland_source = b.dependency("wayland", .{});
    const wayland_protocols_source = b.dependency("wayland_protocols", .{});

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

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_generated_tests.step);
    test_step.dependOn(&run_client_core_tests.step);
    test_step.dependOn(&run_server_core_tests.step);
    test_step.dependOn(&run_end_to_end_tests.step);

    const protocol_compat_test = b.addSystemCommand(&.{ "/bin/sh", "test/protocol-compat.sh" });
    protocol_compat_test.addArtifactArg(scanner);
    protocol_compat_test.addDirectoryArg(wayland_source.path(""));
    protocol_compat_test.addDirectoryArg(wayland_protocols_source.path(""));
    const protocol_compat_step = b.step(
        "protocol-compat",
        "Generate and test pinned upstream Wayland protocols",
    );
    protocol_compat_step.dependOn(&protocol_compat_test.step);

    const build_benchmarks = b.addSystemCommand(&.{ "/bin/sh", "bench/build.sh" });
    build_benchmarks.addDirectoryArg(wayland_source.path(""));
    build_benchmarks.addDirectoryArg(wayland_protocols_source.path(""));
    const benchmark_step = b.step("benchmarks", "Build the benchmark executables");
    benchmark_step.dependOn(&build_benchmarks.step);
}
