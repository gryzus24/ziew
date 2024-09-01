const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = try std.zig.CrossTarget.parse(
            .{ .arch_os_abi = "x86_64-linux-musl" },
        ),
    });
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols");

    const exe = b.addExecutable(.{
        .name = "ziew",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .link_libc = true,
        .single_threaded = true,
        .strip = strip,
    });
    b.installArtifact(exe);
}
