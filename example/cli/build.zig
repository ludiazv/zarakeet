const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vulkan = b.option(bool, "vulkan", "Build the ggml Vulkan backend (requires glslc)") orelse false;

    const dep = b.dependency("zarakeet", .{
        .target = target,
        .optimize = optimize,
        .vulkan = vulkan,
    });

    const exe = b.addExecutable(.{
        .name = "zarakeet-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zarakeet", dep.module("zarakeet"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    // 0.17: b.args is gone; passthru args are no longer observable at
    // configure time. This makes the step uncached (it always runs).
    run.addPassthruArgs();
    b.step("run", "Run zarakeet-cli").dependOn(&run.step);
}
