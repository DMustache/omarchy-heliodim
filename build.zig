const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .small });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
    });
    const exe = b.addExecutable(.{ .name = "heliodim", .root_module = mod });
    b.installArtifact(exe);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Run unit tests").dependOn(&tests.step);
}
