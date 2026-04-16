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

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/util/ext.h"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{
                .name = "ext",
                .module = translate_c.createModule(),
            },
        },
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = strip,
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
    // Use kernel's default 8 MB stack size - avoids one prlimit call on entry.
    // (this number is sourced from the GNU_STACK program header).
    exe.stack_size = (1 << 20) * 4;

    // LTO is needed to cull unused symbols from the executable.
    // (mainly Zig's libc reimplementation of some musl symbols).
    if (optimize != .Debug)
        exe.lto = .full;

    const no_bin = b.option(bool, "no-bin", "Skip emitting binary") orelse false;
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }

    const module_tests = b.addTest(.{
        .root_module = module,
    });
    const tests_run = b.addRunArtifact(module_tests);
    const tests_step = b.step("test", "Run tests");
    tests_step.dependOn(&tests_run.step);
}
