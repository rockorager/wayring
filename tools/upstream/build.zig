const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wayring = b.dependency("wayring", .{
        .target = target,
        .optimize = optimize,
    });
    const wayland = b.lazyDependency("wayland", .{}) orelse return;
    const wayland_protocols = b.lazyDependency("wayland_protocols", .{}) orelse return;
    const scanner = wayring.artifact("wayring-scanner");

    const protocol_compat = b.addSystemCommand(&.{"/bin/sh"});
    protocol_compat.addFileArg(b.path("../../test/protocol-compat.sh"));
    protocol_compat.addArtifactArg(scanner);
    protocol_compat.addDirectoryArg(wayland.path(""));
    protocol_compat.addDirectoryArg(wayland_protocols.path(""));
    const protocol_compat_step = b.step(
        "protocol-compat",
        "Generate and test pinned upstream Wayland protocols",
    );
    protocol_compat_step.dependOn(&protocol_compat.step);

    const benchmarks = b.addSystemCommand(&.{"/bin/sh"});
    benchmarks.addFileArg(b.path("../../bench/build.sh"));
    benchmarks.addDirectoryArg(wayland.path(""));
    benchmarks.addDirectoryArg(wayland_protocols.path(""));
    const benchmark_step = b.step("benchmarks", "Build the benchmark executables");
    benchmark_step.dependOn(&benchmarks.step);
}
