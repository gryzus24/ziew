const std = @import("std");
const cfg = @import("config.zig");
const log = @import("log.zig");
const typ = @import("type.zig");

const ext = @import("util/ext.zig");
const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");
const ustr = @import("util/str.zig");

const w_bat = @import("w_bat.zig");
const w_cpu = @import("w_cpu.zig");
const w_dysk = @import("w_dysk.zig");
const w_mem = @import("w_mem.zig");
const w_net = @import("w_net.zig");
const w_read = @import("w_read.zig");
const w_time = @import("w_time.zig");

const linux = std.os.linux;
const math = std.math;
const mem = std.mem;
const os = std.os;
const posix = std.posix;
const time = std.time;

// This is all dynamic memory available to the program.
// Four 4K pages minus some fiddle with BSS, DATA, and alignment,
// packing everything tightly to avoid internal fragmentation.
var g_bss: [0x4000 - 1024 - 48 - 0x40]u8 align(64) = undefined;

// USR1 signal latch.
var g_refresh_all = false;

const WRITE_FAIL_CHECK = true;

const Args = struct {
    config_path: ?[*:0]const u8 = null,
};

fn showHelpAndExit() noreturn {
    _ = uio.sys_write(2, "usage: ziew [c <config file>] [h] [v]\n");
    linux.exit(0);
}

fn showVersionAndExit() noreturn {
    _ = uio.sys_write(2, "ziew 0.0.12\n");
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
                    _ = uio.sys_write(2, "unknown option\n");
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
        _ = uio.sys_write(2, "required argument: c <path>\n");
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

    var n = ustr.unsafeU64toa(&buf, diag.line_nr);
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

fn loadConfig(reg: *umem.Region, config_path: ?[*:0]const u8) []typ.Widget {
    var path: [*:0]const u8 = undefined;
    var path_sp: ?umem.Region.SavePoint = null;

    if (config_path) |ok| {
        path = ok;
    } else {
        path, path_sp = getConfigPath(reg) catch |e| switch (e) {
            error.NoPath => {
                log.warn(&.{"unknown config file path: using defaults..."});
                return cfg.defaultConfig(reg);
            },
            error.NoSpaceLeft => log.fatal(&.{"config: path too long"}),
        };
    }
    const fd_or_err = uio.open0(path);
    if (path_sp) |ok| reg.restore(ok);

    const fd = fd_or_err catch |e| switch (e) {
        error.FileNotFound, error.AccessDenied => {
            log.warn(&.{ "config: ", @errorName(e), ": ", mem.sliceTo(path, 0) });
            log.warn(&.{"using defaults..."});
            return cfg.defaultConfig(reg);
        },
        else => log.fatal(&.{ "config: open: ", @errorName(e) }),
    };
    defer uio.close(fd);

    const parse_bentry = reg.save(u8, .back);
    defer reg.restore(parse_bentry);

    var bf: uio.BufferedFile = .init(
        fd,
        reg.allocMany(u8, 2048, .back) catch unreachable,
    );
    const scratch: []align(16) u8 = @ptrCast(
        reg.allocMany(u128, 512 / 16, .back) catch unreachable,
    );

    const ret = cfg.parse(reg, &bf.buffer, scratch) catch |e| switch (e) {
        error.NoSpaceLeft => log.fatal(&.{"config: out of memory"}),
        error.NoNewline => log.fatal(&.{"config: line too long"}),
        error.ReadError => log.fatal(&.{"config: file read error"}),
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

fn getConfigPath(reg: *umem.Region) !struct { [*:0]const u8, umem.Region.SavePoint } {
    const sp = reg.save(u8, .front);
    var n: usize = 0;
    if (posix.getenvZ("XDG_CONFIG_HOME")) |ok| {
        n += (try reg.writeStr(ok, .front)).len;
        n += (try reg.writeStr("/ziew/config\x00", .front)).len;
    } else if (posix.getenvZ("HOME")) |ok| {
        n += (try reg.writeStr(ok, .front)).len;
        n += (try reg.writeStr("/.config/ziew/config\x00", .front)).len;
    } else {
        log.warn(&.{"neither $HOME nor $XDG_CONFIG_HOME set!"});
        return error.NoPath;
    }
    return .{ reg.slice(u8, sp, n)[0 .. n - 1 :0], sp };
}

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

    var reg: umem.Region = .init(&g_bss, "main");

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
    var net_state: w_net.NetState = .empty;

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
                net_state = .init(widgets);
                net_state_inited = true;
            }
        },
        else => {},
    };

    var views = try reg.allocMany([]const u8, widgets.len, .front);
    var bufs = try reg.allocMany([typ.WIDGET_BUF_MAX]u8, widgets.len, .front);

    const base = reg.head.ptr;

    _ = uio.sys_write(1, "{\"version\":1}\n[[]");
    refresh: while (true) {
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
        var updated: Update = .{ .net = net_state.netdev == null };

        for (widgets, 0..) |*w, i| {
            w.interval_now -|= sleep_dsec;
            if (w.interval_now == 0) {
                @branchHint(.likely);
                w.interval_now = w.interval;

                var fw: uio.Writer = .fixed(&bufs[i]);
                switch (w.id) {
                    .TIME => w_time.widget(&fw, w, base),
                    .MEM => {
                        if (!updated.mem) {
                            try w_mem.update(&mem_state);
                            updated.mem = true;
                        }
                        w_mem.widget(&fw, w, base, &mem_state);
                    },
                    .CPU => {
                        if (!updated.cpu) {
                            try w_cpu.update(&cpu_state);
                            updated.cpu = true;
                        }
                        w_cpu.widget(&fw, w, base, &cpu_state);
                    },
                    .DISK => w_dysk.widget(&fw, w, base),
                    .NET => {
                        if (!updated.net) {
                            try w_net.update(&reg, &net_state.netdev.?);
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

        while (true) {
            const ret = uio.sys_write(1, dst[0..pos]);
            if (ret < 0) {
                @branchHint(.cold);
                if (ret == -ext.c.EINTR) {
                    if (g_refresh_all) continue :refresh;
                    continue;
                }
                if (WRITE_FAIL_CHECK)
                    log.fatalSys(&.{"main: write: "}, ret);
            }
            break;
        }
        var req = sleep_ts;
        while (true) switch (@as(isize, @bitCast(linux.nanosleep(&req, &req)))) {
            -ext.c.EFAULT => unreachable,
            -ext.c.EINTR => if (g_refresh_all) continue :refresh,
            -ext.c.EINVAL => unreachable,
            else => break,
        };
    }
    unreachable;
}
