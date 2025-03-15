const std = @import("std");
const cfg = @import("config.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const w_bat = @import("w_bat.zig");
const w_cpu = @import("w_cpu.zig");
const w_dysk = @import("w_dysk.zig");
const w_mem = @import("w_mem.zig");
const w_net = @import("w_net.zig");
const w_read = @import("w_read.zig");
const w_time = @import("w_time.zig");
const c = utl.c;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const linux = std.os.linux;
const math = std.math;
const mem = std.mem;
const os = std.os;
const posix = std.posix;
const time = std.time;

const Args = struct {
    config_path: ?[*:0]const u8,
};

fn showHelpAndExit(file: fs.File) noreturn {
    utl.writeStr(file, "usage: ziew [c <config file>] [h] [v]\n");
    linux.exit(0);
}

fn showVersionAndExit(file: fs.File) noreturn {
    utl.writeStr(file, "ziew 0.0.7\n");
    linux.exit(0);
}

fn readArgs() Args {
    const argv = os.argv;

    var config_path: ?[*:0]const u8 = null;
    var get_config_path = false;
    var argi: usize = 1;
    while (argi < argv.len) : (argi += 1) {
        const arg = argv[argi];
        const len = mem.len(arg);
        if (len == 1 or (len == 2 and arg[0] == '-')) {
            switch (arg[len - 1]) {
                'c' => {
                    get_config_path = true;
                    argi += 1;
                },
                'h' => showHelpAndExit(utl.stderr),
                'v' => showVersionAndExit(utl.stderr),
                else => {
                    utl.writeStr(utl.stderr, "unknown option\n");
                    showHelpAndExit(utl.stderr);
                },
            }
        }
        if (argi < argv.len) {
            if (get_config_path) {
                config_path = argv[argi];
                get_config_path = false;
            }
        } else {
            utl.writeStr(utl.stderr, "required argument: ");
            utl.writeStr(utl.stderr, arg[0..len]);
            utl.writeStr(utl.stderr, " <arg>\n");
            showHelpAndExit(utl.stderr);
        }
    }
    return .{ .config_path = config_path };
}

fn fatalConfigParse(e: anyerror, err: cfg.LineParseError) noreturn {
    @branchHint(.cold);
    const log = utl.openLog();
    const prefix = "fatal: ";
    log.log(prefix);
    log.log("config: ");
    log.log(@errorName(e));
    if (err.note.len > 0) {
        log.log(": ");
        log.log(err.note);
    }
    log.log("\n");
    log.log(utl.bssPrint("{:<7}{s}\n", .{ err.nr, err.line }));
    const beg = @min(err.ebeg, utl.bss.len);
    const len = @min(err.elen, utl.bss.len);
    if (len != 0) {
        log.log(" " ** prefix.len);
        @memset(utl.bss[0..beg], ' ');
        log.log(utl.bss[0..beg]);
        @memset(utl.bss[0..len], '~');
        log.log(utl.bss[0..len]);
        log.log("\n");
    }
    linux.exit(1);
}

fn readConfig(reg: *m.Region, config_path: ?[*:0]const u8) []const typ.Widget {
    var widgets: []const typ.Widget = undefined;

    const err = blk: {
        if (config_path) |path| {
            if (cfg.readFile(reg, path)) |config_view| {
                var err: cfg.LineParseError = undefined;
                widgets = cfg.parse(reg, config_view, &err) catch |e| {
                    fatalConfigParse(e, err);
                };
                if (widgets.len == 0) {
                    utl.warn(&.{"no widgets loaded: using defaults..."});
                    break :blk true;
                } else {
                    break :blk false;
                }
            } else |e| switch (e) {
                error.FileNotFound => {
                    utl.warn(&.{"no config file: using defaults..."});
                    break :blk true;
                },
                error.NoSpaceLeft => {
                    utl.warn(&.{"config file too big: using defaults..."});
                    break :blk true;
                },
            }
        } else {
            utl.warn(&.{"unknown config file path: using defaults..."});
            break :blk true;
        }
    };
    if (err)
        widgets = cfg.defaultConfig(reg);

    return widgets;
}

fn defaultConfigPath(reg: *m.Region) error{NoSpaceLeft}!?[*:0]const u8 {
    var n: usize = 0;
    const base = reg.frontSave(u8);
    if (posix.getenvZ("XDG_CONFIG_HOME")) |xdg_config_home| {
        n += (try reg.frontWriteStr(xdg_config_home)).len;
        n += (try reg.frontWriteStr("/ziew/config\x00")).len;
    } else if (posix.getenvZ("HOME")) |home| {
        n += (try reg.frontWriteStr(home)).len;
        n += (try reg.frontWriteStr("/.config/ziew/config\x00")).len;
    } else {
        utl.warn(&.{"$HOME and $XDG_CONFIG_HOME not set"});
        return null;
    }
    return reg.slice(u8, base, n)[0 .. n - 1 :0];
}

var g_refresh_all = false;
var g_bss_memory: [8 * heap.pageSize()]u8 align(16) = undefined;

fn sa_handler(signum: c_int) callconv(.C) void {
    if (signum == linux.SIG.USR1) g_refresh_all = true;
}

pub fn main() !void {
    var reg: m.Region = .init(&g_bss_memory);

    const args = readArgs();
    const config_path = args.config_path orelse (defaultConfigPath(&reg) catch |e| switch (e) {
        error.NoSpaceLeft => utl.fatal(&.{"config path too long"}),
    });
    const widgets = readConfig(&reg, config_path);

    if (linux.sigaction(linux.SIG.USR1, &.{
        .handler = .{ .handler = &sa_handler },
        .mask = linux.empty_sigset,
        .flags = linux.SA.RESTART,
    }, null) != 0) {
        utl.fatal(&.{"sigaction failed"});
    }

    const sleep_interval_dsec = blk: {
        var min: typ.DeciSec = typ.WIDGET_INTERVAL_MAX;
        var gcd: typ.DeciSec = 0;
        for (widgets) |*w| {
            // Intervals of `WIDGET_INTERVAL_MAX` are
            // treated as "refresh once and forget".
            if (w.interval != typ.WIDGET_INTERVAL_MAX) {
                min = @min(min, w.interval);
                gcd = math.gcd(if (gcd == 0) w.interval else gcd, w.interval);
            }
        }
        if (gcd < min) {
            utl.warn(
                &.{"gcd of intervals < minimum interval, widget refreshes will be inexact"},
            );
        }
        // NOTE: gcd is the obvious choice here, but it might prove
        //       disastrous if the interval is misconfigured...
        break :blk min;
    };
    const sleep_interval_ts: linux.timespec = .{
        .sec = @intCast(sleep_interval_dsec / 10),
        .nsec = @intCast((sleep_interval_dsec % 10) * time.ns_per_s / 10),
    };

    var cpu_state: w_cpu.CpuState = undefined;
    var mem_state: w_mem.MemState = undefined;
    var net_state: ?w_net.NetState = null;

    var mem_state_inited = false;
    var cpu_state_inited = false;
    var net_state_inited = false;

    for (widgets) |*w| switch (w.wid) {
        .CPU => {
            if (!cpu_state_inited) {
                cpu_state = .init();
                cpu_state_inited = true;
            }
        },
        .MEM => {
            if (!mem_state_inited) {
                mem_state = .init();
                mem_state_inited = true;
            }
        },
        .NET => {
            if (!net_state_inited) {
                net_state = .init(&reg, widgets);
                net_state_inited = true;
            }
        },
        else => {},
    };

    // zig fmt: off
    var time_to_refresh   = try reg.frontAllocMany(typ.DeciSec, widgets.len);
    var widget_bufs       = try reg.frontAllocMany([typ.WIDGET_BUF_MAX]u8, widgets.len);
    var widget_bufs_views = try reg.frontAllocMany([]const u8, widgets.len);
    var write_buf         = try reg.frontAllocMany(u8, 2 + widgets.len * typ.WIDGET_BUF_MAX);
    // zig fmt: on

    write_buf[0] = ',';
    write_buf[1] = '[';

    const header =
        \\{"version":1}
        \\[[]
    ;
    _ = linux.write(1, header, header.len);
    while (true) {
        if (g_refresh_all) {
            @memset(time_to_refresh, 0);
            g_refresh_all = false;
        }

        var cpu_updated = false;
        var mem_updated = false;
        var net_updated = false;

        for (widgets, 0..) |*w, i| {
            time_to_refresh[i] -|= sleep_interval_dsec;
            if (time_to_refresh[i] == 0) {
                time_to_refresh[i] = w.interval;

                var fbs = io.fixedBufferStream(&widget_bufs[i]);

                if (w.wid == .CPU and !cpu_updated) {
                    w_cpu.update(&cpu_state);
                    cpu_updated = true;
                }
                if (w.wid == .MEM and !mem_updated) {
                    w_mem.update(&mem_state);
                    mem_updated = true;
                }
                if (w.wid == .NET and !net_updated) {
                    if (net_state) |*ok| {
                        w_net.update(ok);
                        net_updated = true;
                    }
                }
                widget_bufs_views[i] = switch (w.wid) {
                    .TIME => w_time.widget(&fbs, w),
                    .MEM => w_mem.widget(&fbs, &mem_state, w),
                    .CPU => w_cpu.widget(&fbs, &cpu_state, w),
                    .DISK => w_dysk.widget(&fbs, w),
                    .NET => w_net.widget(&fbs, &net_state, w),
                    .BAT => w_bat.widget(&fbs, w),
                    .READ => w_read.widget(&fbs, w),
                };
            }
        }

        var pos: usize = 2;
        for (widget_bufs_views) |view| {
            @memcpy(write_buf[pos .. pos + view.len], view);
            pos += view.len;
        }
        write_buf[pos - 1] = ']'; // get rid of the trailing comma

        _ = linux.write(1, write_buf.ptr, pos);

        var req = sleep_interval_ts;
        while (true) switch (posix.errno(linux.nanosleep(&req, &req))) {
            .INTR => if (g_refresh_all) break,
            .INVAL => unreachable,
            else => break,
        };
    }

    unreachable;
}
