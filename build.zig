const std = @import("std");

pub fn build(b: *std.Build) !void {
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
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

    const target = b.standardTargetOptions(.{
        .default_target = try std.Target.Query.parse(
            .{
                .arch_os_abi = "x86_64-linux-musl",
                .cpu_features = march,
            },
        ),
    });
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
        .strip = strip,
        .single_threaded = true,
        .omit_frame_pointer = omit_frame_pointer,
    });

    const mem_no_oom_check =
        b.option(bool, "mem-no-oom-check", "Disable memory allocation bounds checking") orelse false;
    const mem_trace_allocations =
        b.option(bool, "mem-trace-allocations", "Enable memory allocation tracing") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "mem_no_oom_check", mem_no_oom_check);
    options.addOption(bool, "mem_trace_allocations", mem_trace_allocations);

    module.addOptions("config", options);
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
