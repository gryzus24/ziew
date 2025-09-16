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
    config_path: ?[*:0]const u8 = null,
};

fn showHelpAndExit() noreturn {
    utl.fdWrite(2, "usage: ziew [c <config file>] [h] [v]\n");
    linux.exit(0);
}

fn showVersionAndExit() noreturn {
    utl.fdWrite(2, "ziew 0.0.8\n");
    linux.exit(0);
}

fn readArgs() Args {
    const argv = os.argv;

    var args: Args = .{};
    var get_config_path = false;

    for (1..argv.len) |i| {
        const arg = argv[i];
        const len = mem.len(arg);
        if (len == 1 or (len == 2 and arg[0] == '-')) {
            switch (arg[len - 1]) {
                'c' => {
                    get_config_path = true;
                    continue;
                },
                'h' => showHelpAndExit(),
                'v' => showVersionAndExit(),
                else => {
                    utl.fdWrite(2, "unknown option\n");
                    showHelpAndExit();
                },
            }
        }
        if (get_config_path) {
            args.config_path = argv[i];
            get_config_path = false;
        }
    }
    if (get_config_path) {
        utl.fdWrite(2, "required argument: c <path>\n");
        showHelpAndExit();
    }
    return args;
}

fn fatalConfig(diag: cfg.ParseResult.Diagnostic) noreturn {
    @branchHint(.cold);
    const log = utl.openLog();
    log.log("fatal: config: ");
    log.log(diag.note);
    log.log("\n");
    log.log(utl.bssPrint("{:<7}{s}\n", .{ diag.line_nr, diag.line }));
    const beg = @min(diag.field.beg, m.g_logging_bss.len);
    const end = @min(diag.field.end, m.g_logging_bss.len);
    if (beg < end) {
        log.log(" " ** 7);
        @memset(m.g_logging_bss[0..beg], ' ');
        log.log(m.g_logging_bss[0..beg]);
        @memset(m.g_logging_bss[0 .. end - beg], '~');
        log.log(m.g_logging_bss[0 .. end - beg]);
        log.log("\n");
    }
    linux.exit(1);
}

fn loadConfig(reg: *m.Region, config_path: ?[*:0]const u8) []typ.Widget {
    @branchHint(.cold);

    const path: [*:0]const u8 = blk: {
        if (config_path) |ok| {
            break :blk ok;
        } else {
            if (getConfigPath(reg)) |ok| {
                break :blk ok;
            } else |e| switch (e) {
                error.NoPath => {
                    utl.warn(&.{"unknown config file path: using defaults..."});
                    return cfg.defaultConfig(reg);
                },
                error.NoSpaceLeft => utl.fatal(&.{"config path too long"}),
            }
        }
    };

    const file = fs.cwd().openFileZ(path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            utl.warn(&.{ "config: file not found: ", path[0..mem.len(path)] });
            utl.warn(&.{"using defaults..."});
            return cfg.defaultConfig(reg);
        },
        else => utl.fatal(&.{ "config: open: ", @errorName(e) }),
    };
    defer file.close();

    var linebuf: [256]u8 = undefined;
    var scratch: [256]u8 align(16) = undefined;

    var reader = file.reader(&linebuf);

    const ret = cfg.parse(reg, &reader.interface, &scratch) catch |e| switch (e) {
        error.NoSpaceLeft => utl.fatal(&.{"config: out of memory"}),
    };
    const widgets = switch (ret) {
        .ok => |w| w,
        .err => |diag| fatalConfig(diag),
    };

    if (widgets.len == 0) {
        utl.warn(&.{"no widgets loaded: using defaults..."});
        return cfg.defaultConfig(reg);
    }
    return widgets;
}

fn getConfigPath(reg: *m.Region) error{ NoSpaceLeft, NoPath }![*:0]const u8 {
    var n: usize = 0;
    const base = reg.frontSave(u8);
    if (posix.getenvZ("XDG_CONFIG_HOME")) |ok| {
        n += (try reg.frontWriteStr(ok)).len;
        n += (try reg.frontWriteStr("/ziew/config\x00")).len;
    } else if (posix.getenvZ("HOME")) |ok| {
        n += (try reg.frontWriteStr(ok)).len;
        n += (try reg.frontWriteStr("/.config/ziew/config\x00")).len;
    } else {
        utl.warn(&.{"neither $HOME nor $XDG_CONFIG_HOME set!"});
        return error.NoPath;
    }
    return reg.slice(u8, base, n)[0 .. n - 1 :0];
}

var g_refresh_all = false;
fn sa_handler(signum: c_int) callconv(.c) void {
    if (signum == linux.SIG.USR1) g_refresh_all = true;
}

fn setupSignals() void {
    const action: linux.Sigaction = .{
        .handler = .{ .handler = &sa_handler },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };

    if (linux.sigaction(linux.SIG.USR1, &action, null) != 0) {
        utl.fatal(&.{"sigaction failed"});
    }
}

fn sleepInterval(widgets: []const typ.Widget) typ.DeciSec {
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
        utl.warn(&.{"gcd of intervals < minimum interval, widget refreshes will be inexact"});
    }
    // NOTE: gcd is the obvious choice here, but it might prove
    //       disastrous if the interval is misconfigured...
    return min;
}

pub fn main() !void {
    var reg: m.Region = .init(&m.g_bss, "main");

    const args = readArgs();
    const widgets = loadConfig(&reg, args.config_path);

    setupSignals();

    const sleep_dsec = sleepInterval(widgets);
    const sleep_ts: linux.timespec = .{
        .sec = sleep_dsec / 10,
        .nsec = (sleep_dsec % 10) * (time.ns_per_s / 10),
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
                cpu_state = try .init(&reg);
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

    var views = try reg.frontAllocMany([]const u8, widgets.len);
    var bufs = try reg.frontAllocMany([typ.WIDGET_BUF_MAX]u8, widgets.len);

    const base = reg.head.ptr;

    utl.fdWrite(1, "{\"version\":1}\n[[]");
    while (true) {
        if (g_refresh_all) {
            @branchHint(.unlikely);
            for (widgets) |*w| w.interval_now = 0;
            g_refresh_all = false;
        }

        var cpu_updated = false;
        var mem_updated = false;
        var net_updated = false;

        for (widgets, 0..) |*w, i| {
            w.interval_now -|= sleep_dsec;
            if (w.interval_now == 0) {
                @branchHint(.likely);
                w.interval_now = w.interval;

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

                var fw: io.Writer = .fixed(&bufs[i]);
                views[i] = switch (w.wid) {
                    .TIME => w_time.widget(&fw, w),
                    .MEM => w_mem.widget(&fw, &mem_state, w, base),
                    .CPU => w_cpu.widget(&fw, &cpu_state, w, base),
                    .DISK => w_dysk.widget(&fw, w, base),
                    .NET => w_net.widget(&fw, &net_state, w, base),
                    .BAT => w_bat.widget(&fw, w, base),
                    .READ => w_read.widget(&fw, w, base),
                };
            }
        }

        const dst = base[reg.front..reg.back];

        dst[0] = ',';
        dst[1] = '[';

        var pos: usize = 2;
        for (views) |view| {
            @memcpy(dst[pos .. pos + view.len], view);
            pos += view.len;
        }
        dst[pos - 1] = ']'; // get rid of the trailing comma

        utl.fdWrite(1, dst[0..pos]);

        var req = sleep_ts;
        while (true) switch (@as(isize, @bitCast(linux.nanosleep(&req, &req)))) {
            -c.EFAULT => unreachable,
            -c.EINTR => if (g_refresh_all) break,
            -c.EINVAL => unreachable,
            else => break,
        };
    }
    unreachable;
}
