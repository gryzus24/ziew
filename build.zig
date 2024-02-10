const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = try std.zig.CrossTarget.parse(
            .{ .arch_os_abi = "x86_64-linux-musl" },
        ),
    });
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols");

    const build_options = b.addOptions();
    build_options.addOption(
        []const u8,
        "compile_config_filename",
        b.option([]const u8, "compile-config",
            \\Compile the configuration file into the executable,
            \\                               [string] is the filename of the configuration
            \\                               file residing in src
        ) orelse "",
    );

    const exe = b.addExecutable(.{
        .name = "ziew",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .link_libc = true,
        .single_threaded = true,
    });
    exe.strip = strip orelse false;
    exe.addOptions("build", build_options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
