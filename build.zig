const std = @import("std");

pub fn build(b: *std.Build) !void {
    const march = b.option(
        []const u8,
        "march",
        "Enable optional CPU features (use -Dmarch=native to optimize for your CPU)",
    ) orelse "baseline";
    const omit_frame_pointer = b.option(
        bool,
        "omit-frame-pointer",
        "Disable generating frame pointer chains",
    ) orelse false;
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{
            .default_target = try std.Target.Query.parse(
                .{
                    .arch_os_abi = "x86_64-linux-musl",
                    .cpu_features = march,
                },
            ),
        }),
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .single_threaded = true,
        .omit_frame_pointer = omit_frame_pointer,
    });

    const exe = b.addExecutable(.{
        .name = "ziew",
        .root_module = module,
        .linkage = .static,
    });

    const no_bin = b.option(bool, "no-bin", "Skip emitting binary") orelse false;
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }
}
