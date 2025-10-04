const std = @import("std");
const c = @import("c.zig").c;
const cfg = @import("config.zig");
const typ = @import("type.zig");

const iou = @import("util/io.zig");
const log = @import("util/log.zig");
const m = @import("util/mem.zig");
const su = @import("util/str.zig");

const w_bat = @import("w_bat.zig");
const w_cpu = @import("w_cpu.zig");
const w_dysk = @import("w_dysk.zig");
const w_mem = @import("w_mem.zig");
const w_net = @import("w_net.zig");
const w_read = @import("w_read.zig");
const w_time = @import("w_time.zig");

const fs = std.fs;
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
    iou.fdWrite(2, "usage: ziew [c <config file>] [h] [v]\n");
    linux.exit(0);
}

fn showVersionAndExit() noreturn {
    iou.fdWrite(2, "ziew 0.0.11\n");
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
                    iou.fdWrite(2, "unknown option\n");
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
        iou.fdWrite(2, "required argument: c <path>\n");
        showHelpAndExit();
    }
    return args;
}

fn fatalConfig(diag: cfg.ParseResult.Diagnostic) noreturn {
    @branchHint(.cold);
    const l: log.Log = .open();
    l.log("fatal: config: ");
    l.log(diag.note);
    l.log("\n");

    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    var n = su.unsafeU64toa(&buf, diag.line_nr);
    @memcpy(buf[pos..][0..n], buf[buf.len - n ..]);
    pos += n;

    n = 7 -| n;
    @memset(buf[pos..][0..n], ' ');
    pos += n;

    n = @min(diag.line.len, buf.len - pos);
    @memcpy(buf[pos..][0..n], diag.line[0..n]);
    pos += n;

    l.log(buf[0..pos]);
    l.log("\n");

    const beg = @min(diag.field.beg, buf.len);
    const end = @min(diag.field.end, buf.len);
    if (beg < end) {
        l.log(" " ** 7);
        @memset(buf[0..beg], ' ');
        l.log(buf[0..beg]);
        @memset(buf[0 .. end - beg], '~');
        l.log(buf[0 .. end - beg]);
        l.log("\n");
    }
    linux.exit(1);
}

fn loadConfig(reg: *m.Region, config_path: ?[*:0]const u8) []typ.Widget {
    const path = config_path orelse getConfigPath(reg) catch |e| switch (e) {
        error.NoPath => {
            log.warn(&.{"unknown config file path: using defaults..."});
            return cfg.defaultConfig(reg);
        },
        error.NoSpaceLeft => log.fatal(&.{"config path too long"}),
    };

    const file = fs.cwd().openFileZ(path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            log.warn(&.{ "config: file not found: ", mem.sliceTo(path, 0) });
            log.warn(&.{"using defaults..."});
            return cfg.defaultConfig(reg);
        },
        else => log.fatal(&.{ "config: open: ", @errorName(e) }),
    };
    defer file.close();

    var linebuf: [256]u8 = undefined;
    var scratch: [256]u8 align(16) = undefined;

    var reader = file.reader(&linebuf);

    const ret = cfg.parse(reg, &reader.interface, &scratch) catch |e| switch (e) {
        error.NoSpaceLeft => log.fatal(&.{"config: out of memory"}),
    };
    const widgets = switch (ret) {
        .ok => |w| w,
        .err => |diag| fatalConfig(diag),
    };

    if (widgets.len == 0) {
        log.warn(&.{"no widgets loaded: using defaults..."});
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
        log.warn(&.{"neither $HOME nor $XDG_CONFIG_HOME set!"});
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
        log.fatal(&.{"sigaction failed"});
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
        log.warn(&.{"gcd of intervals < minimum interval, widget refreshes will be inexact"});
    }
    // NOTE: gcd is the obvious choice here, but it might prove
    //       disastrous if the interval is misconfigured...
    return min;
}

pub fn main() void {
    errdefer |e| log.fatal(&.{ "main: ", @errorName(e) });

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

    for (widgets) |*w| switch (w.id) {
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

    iou.fdWrite(1, "{\"version\":1}\n[[]");
    while (true) {
        if (g_refresh_all) {
            @branchHint(.unlikely);
            for (widgets) |*w| w.interval_now = 0;
            g_refresh_all = false;
        }

        const Update = packed struct(u32) {
            net: bool = false,
            cpu: bool = false,
            mem: bool = false,
            _: u29 = 0,
        };
        var updated: Update = .{ .net = net_state == null };

        for (widgets, 0..) |*w, i| {
            w.interval_now -|= sleep_dsec;
            if (w.interval_now == 0) {
                @branchHint(.likely);
                w.interval_now = w.interval;

                var fw: io.Writer = .fixed(&bufs[i]);
                switch (w.id) {
                    .TIME => w_time.widget(&fw, w, base),
                    .MEM => {
                        if (!updated.mem) {
                            w_mem.update(&mem_state);
                            updated.mem = true;
                        }
                        w_mem.widget(&fw, w, base, &mem_state);
                    },
                    .CPU => {
                        if (!updated.cpu) {
                            w_cpu.update(&cpu_state);
                            updated.cpu = true;
                        }
                        w_cpu.widget(&fw, w, base, &cpu_state);
                    },
                    .DISK => w_dysk.widget(&fw, w, base),
                    .NET => {
                        if (!updated.net) {
                            w_net.update(&net_state.?);
                            updated.net = true;
                        }
                        w_net.widget(&fw, w, base, &net_state);
                    },
                    .BAT => w_bat.widget(&fw, w, base),
                    .READ => w_read.widget(&fw, w, base),
                }
                views[i] = typ.writeWidgetEnd(&fw);
            }
        }

        const dst = base[reg.front..reg.back];
        dst[0..2].* = ",[".*;

        var pos: usize = 2;
        for (views) |view| {
            dst[pos..][0..64].* = view.ptr[0..64].*;
            if (view.len > 64) {
                @branchHint(.unlikely);
                const e = (view.len + 15) & ~@as(usize, 0x0f);
                var i: usize = 64;
                while (true) {
                    dst[pos + i ..][0..16].* = view.ptr[i..][0..16].*;
                    i += 16;
                    if (i == e)
                        break;
                }
            }
            pos += view.len;
        }
        dst[pos - 1] = ']'; // get rid of the trailing comma

        iou.fdWrite(1, dst[0..pos]);

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
