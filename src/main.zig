const std = @import("std");
const cfg = @import("config.zig");
const log = @import("log.zig");
const typ = @import("type.zig");

const ext = @import("util/ext.zig");
const misc = @import("util/misc.zig");
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
const mem = std.mem;
const process = std.process;
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

    fn get(argv: process.Args.Vector, i: usize) ?struct { [*:0]const u8, usize } {
        return if (i < argv.len) .{ argv[i], i } else null;
    }

    fn read(argv: process.Args.Vector) @This() {
        var args: Args = .{};
        var i: usize = 0;

        next: switch (enum { arg, c, h, v }.arg) {
            .arg => {
                const arg, i = Args.get(argv, i + 1) orelse return args;
                const len = mem.len(arg);
                if (len == 1 or (len == 2 and arg[0] == '-')) {
                    if (arg[len - 1] == 'c') continue :next .c;
                    if (arg[len - 1] == 'h') continue :next .h;
                    if (arg[len - 1] == 'v') continue :next .v;
                }
                _ = uio.sys_writev(2, .{ "unknown option: '", arg[0..len], "'\n" });
                continue :next .h;
            },
            .c => {
                if (Args.get(argv, i + 1)) |ok| {
                    args.config_path, i = ok;
                    continue :next .arg;
                }
                _ = uio.sys_write(2, "required argument: c <path>\n");
            },
            .h => _ = uio.sys_write(2, "usage: ziew [c <config file>] [h] [v]\n"),
            .v => _ = uio.sys_write(2, "ziew 0.0.13\n"),
        }
        linux.exit(0);
    }
};

const WidgetStates = struct {
    mem: w_mem.State,
    cpu: w_cpu.State,
    disk: w_dysk.State,
    net: w_net.State,

    fn init() @This() {
        return .{
            .mem = undefined,
            .cpu = undefined,
            .disk = undefined,
            .net = .empty,
        };
    }
};

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

fn loadConfig(reg: *umem.Region, config_path: ?[*:0]const u8, env: process.Environ) []typ.Widget {
    var path: [*:0]const u8 = undefined;
    var path_sp: ?umem.Region.SavePoint = null;

    if (config_path) |ok| {
        path = ok;
    } else {
        path, path_sp = getConfigPath(reg, env) catch |e| switch (e) {
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

const ConfigPathError = error{NoPath} || umem.Region.Error;
const ConfigPathResult = struct { [*:0]const u8, umem.Region.SavePoint };

fn getConfigPath(reg: *umem.Region, env: process.Environ) ConfigPathError!ConfigPathResult {
    const sp = reg.save(u8, .front);
    var n: usize = 0;

    if (env.getPosix("XDG_CONFIG_HOME")) |ok| {
        n += (try reg.writeStr(ok, .front)).len;
        n += (try reg.writeStr("/ziew/config\x00", .front)).len;
    } else if (env.getPosix("HOME")) |ok| {
        n += (try reg.writeStr(ok, .front)).len;
        n += (try reg.writeStr("/.config/ziew/config\x00", .front)).len;
    } else {
        log.warn(&.{"neither $HOME nor $XDG_CONFIG_HOME set!"});
        return error.NoPath;
    }
    return .{ reg.slice(u8, sp, n)[0 .. n - 1 :0], sp };
}

fn sa_handler(signum: linux.SIG) callconv(.c) void {
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
    var min: typ.UDeciSec = typ.WIDGET_INTERVAL_MAX;
    var gcd: typ.UDeciSec = 0;
    for (widgets) |*w| {
        // Intervals of `WIDGET_INTERVAL_MAX` are
        // treated as "refresh once and forget".
        const interval: typ.UDeciSec = @intCast(w.interval.set);
        if (interval != typ.WIDGET_INTERVAL_MAX) {
            min = @min(min, interval);
            gcd = misc.gcd(if (gcd == 0) interval else gcd, interval);
        }
    }
    if (gcd < min) {
        log.warn(&.{"GCD of intervals < shortest interval, widget updates will be inexact"});
    }
    // NOTE: gcd is the obvious choice here, but it might prove
    //       disastrous if the interval is misconfigured...
    return @intCast(min);
}

fn setupWidgets(reg: *umem.Region, widgets: []typ.Widget, states: *WidgetStates) !void {
    var intervals: [4]typ.DeciSec = @splat(typ.WIDGET_INTERVAL_MAX);
    var inited: [4]bool = @splat(false);
    const mem_i = 0;
    const cpu_i = 1;
    const net_i = 2;
    const disk_i = 3;

    for (widgets) |*w| switch (w.id) {
        .MEM => {
            if (!inited[mem_i]) {
                states.mem = .init();
                inited[mem_i] = true;
            }
            intervals[mem_i] = @min(intervals[mem_i], w.interval.set);
        },
        .CPU => {
            if (!inited[cpu_i]) {
                states.cpu = try .init(reg, widgets);
                inited[cpu_i] = true;
            }
            intervals[cpu_i] = @min(intervals[cpu_i], w.interval.set);
        },
        .DISK => {
            if (!inited[disk_i]) {
                states.disk = try .init(reg, widgets);
                inited[disk_i] = true;
            }
            // DISK widgets perform per mountpoint updates,
            // no need to clamp the interval.
        },
        .NET => {
            if (!inited[net_i]) {
                states.net = .init(widgets);
                inited[net_i] = true;
            }
            intervals[net_i] = @min(intervals[net_i], w.interval.set);
        },
        else => {},
    };
    for (widgets) |*w| switch (w.id) {
        .CPU => w.interval.set = intervals[cpu_i],
        .MEM => w.interval.set = intervals[mem_i],
        .NET => w.interval.set = intervals[net_i],
        else => {},
    };
}

fn update(
    reg: *umem.Region,
    widgets: []typ.Widget,
    states: *WidgetStates,
    bufs: [][typ.WIDGET_BUF_MAX]u8,
    vecs: [][]const u8,
    sleep_dsec: typ.DeciSec,
) !void {
    const base = reg.head.ptr;

    const Update = packed struct(u32) {
        net: bool = false,
        mem: bool = false,
        cpu: bool = false,
        _: u29 = 0,
    };
    var updated: Update = .{ .net = states.net.netdev == null };

    for (widgets, 0..) |*w, i| {
        w.interval.now -= sleep_dsec;
        if (w.interval.now <= 0) {
            var fw: uio.Writer = .fixed(bufs[i][0..typ.WIDGET_BUF_WRITABLE]);
            const parts = w.format.parts.get(base);
            switch (w.id) {
                .TIME => w_time.widget(&fw, w, parts, base),
                .MEM => {
                    if (!updated.mem) {
                        try w_mem.update(&states.mem);
                        updated.mem = true;
                    }
                    w_mem.widget(&fw, w, parts, base, &states.mem);
                },
                .CPU => {
                    if (!updated.cpu) {
                        try w_cpu.update(&states.cpu);
                        updated.cpu = true;
                    }
                    w_cpu.widget(&fw, w, parts, base, &states.cpu);
                },
                .DISK => w_dysk.widget(&fw, w, parts, base, &states.disk),
                .NET => {
                    if (!updated.net) {
                        try w_net.update(reg, &states.net.netdev.?);
                        updated.net = true;
                    }
                    w_net.widget(&fw, w, parts, base, &states.net);
                },
                .BAT => w_bat.widget(&fw, w, parts, base),
                .READ => w_read.widget(&fw, w, parts, base),
            }
            w.format.last_str.writeBytes(&fw, base);
            vecs[i] = typ.writeWidgetEnd(&bufs[i], fw.end);
            w.interval.now = w.interval.set;
        }
    }
}

fn copy(dst: []u8, vecs: []const []const u8) []const u8 {
    dst[0..2].* = ",[".*;
    var pos: usize = 2;
    for (vecs) |vec| {
        dst[pos..][0..64].* = vec.ptr[0..64].*;
        if (vec.len > 64) {
            @branchHint(.unlikely);
            const e = (vec.len + 15) & ~@as(usize, 0x0f);
            var i: usize = 64;
            while (true) {
                dst[pos + i ..][0..16].* = vec.ptr[i..][0..16].*;
                i += 16;
                if (i == e)
                    break;
            }
        }
        pos += vec.len;
    }
    dst[pos - 1] = ']'; // get rid of the trailing comma
    return dst[0..pos];
}

pub fn main(init: process.Init.Minimal) void {
    errdefer |e| log.fatal(&.{ "main: ", @errorName(e) });

    var reg: umem.Region = .init(&g_bss, "main");

    const args: Args = .read(init.args.vector);
    const widgets = loadConfig(&reg, args.config_path, init.environ);

    setupSignals();

    const sleep_dsec = sleepInterval(widgets);
    const sleep_ts: linux.timespec = .{
        .sec = @divTrunc(sleep_dsec, 10),
        .nsec = @rem(sleep_dsec, 10) * (time.ns_per_s / 10),
    };

    var states: WidgetStates = .init();
    try setupWidgets(&reg, widgets, &states);

    const vecs = try reg.allocMany([]const u8, widgets.len, .front);
    const bufs = try reg.allocMany([typ.WIDGET_BUF_MAX]u8, widgets.len, .front);

    const base = reg.head.ptr;

    _ = uio.sys_write(1, "{\"version\":1}\n[[]");
    refresh: while (true) {
        if (g_refresh_all) {
            @branchHint(.unlikely);
            for (widgets) |*w| w.interval.now = 0;
            g_refresh_all = false;
        }
        try update(&reg, widgets, &states, bufs, vecs, sleep_dsec);
        const p = copy(base[reg.front..reg.back], vecs);

        while (true) {
            const ret = uio.sys_write(1, p);
            if (ret >= 0) break;
            if (ret == -ext.c.EINTR) {
                if (g_refresh_all)
                    continue :refresh;
                continue;
            }
            if (WRITE_FAIL_CHECK)
                log.fatalSys(&.{"main: write: "}, ret);
        }
        var req = sleep_ts;
        while (true) {
            if (linux.nanosleep(&req, &req) == 0) break;
            // Only EINTR is reachable here.
            if (g_refresh_all) continue :refresh;
        }
    }
    unreachable;
}

test "all tests" {
    _ = @import("config.zig");
    _ = @import("w_mem.zig");
    _ = @import("w_cpu.zig");
    _ = @import("w_net.zig");
}
