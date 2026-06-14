const std = @import("std");

pub fn build(b: *std.Build) !void {
    const glibc = b.option(bool, "glibc", "Link dynamically against glibc") orelse false;
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
    const config_path = b.option(
        []const u8,
        "config",
        "Embed a configuration file into the executable to reduce its size",
    ) orelse null;

    const triple, const linkage: std.builtin.LinkMode = blk: {
        if (glibc) {
            break :blk .{ "x86_64-linux-gnu", .dynamic };
        } else {
            break :blk .{ "x86_64-linux-musl", .static };
        }
    };

    const target = b.standardTargetOptions(.{
        .default_target = try std.Target.Query.parse(
            .{
                .arch_os_abi = triple,
                .cpu_features = march,
            },
        ),
    });
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = true;

    const tc_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/util/ext.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const mem_no_oom_check =
        b.option(bool, "mem-no-oom-check", "Disable memory allocation bounds checking") orelse false;
    const mem_trace_allocations =
        b.option(bool, "mem-trace-allocations", "Enable memory allocation tracing") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "mem_no_oom_check", mem_no_oom_check);
    options.addOption(bool, "mem_trace_allocations", mem_trace_allocations);
    options.addOption(bool, "is_embedding_config", config_path != null);
    const options_mod = options.createModule();

    var modules: [2]*std.Build.Module = undefined;
    for (&[2][]const u8{ "src/main.zig", "dump_config.zig" }, 0..) |path, i| {
        modules[i] = b.createModule(.{
            .root_source_file = b.path(path),
            .imports = &.{
                .{
                    .name = "ext",
                    .module = tc_mod,
                },
                .{
                    .name = "config",
                    .module = options_mod,
                },
            },
            .target = target,
            .optimize = optimize,
            .single_threaded = single_threaded,
            .strip = strip,
            .omit_frame_pointer = omit_frame_pointer,
        });
    }
    const main_mod, const dump_mod = modules;

    if (config_path) |ok| {
        const dump_exe_run = b.addRunArtifact(
            b.addExecutable(.{
                .name = "dump-config",
                .root_module = dump_mod,
                .linkage = linkage,
            }),
        );
        // User might update the config file without changing
        // the -Dconfig option - prevent caching the run step.
        dump_exe_run.has_side_effects = true;

        dump_exe_run.addArg(ok);
        main_mod.addAnonymousImport("config.data", .{
            .root_source_file = dump_exe_run.addOutputFileArg("config.data"),
        });
        main_mod.addAnonymousImport("config.widgets", .{
            .root_source_file = dump_exe_run.addOutputFileArg("config.widgets"),
        });
        main_mod.addAnonymousImport("config.intervals", .{
            .root_source_file = dump_exe_run.addOutputFileArg("config.intervals"),
        });
    }

    const main_exe = b.addExecutable(.{
        .name = "ziew",
        .root_module = main_mod,
        .linkage = linkage,
    });
    // Use kernel's default 8 MB stack size - avoids one prlimit call on entry.
    // (this number is sourced from the GNU_STACK program header).
    main_exe.stack_size = (1 << 20) * 8;

    // LTO is needed to cull unused symbols from the executable.
    // (mainly Zig's libc reimplementation of some musl symbols).
    if (optimize != .Debug)
        main_exe.lto = .full;

    const no_bin = b.option(bool, "no-bin", "Skip emitting binary") orelse false;
    if (no_bin) {
        b.getInstallStep().dependOn(&main_exe.step);
    } else {
        b.getInstallStep().dependOn(&b.addInstallArtifact(main_exe, .{}).step);
    }

    const main_tests = b.addTest(.{ .root_module = main_mod });
    const tests_step = b.step("test", "Run tests");
    tests_step.dependOn(&b.addRunArtifact(main_tests).step);
}
