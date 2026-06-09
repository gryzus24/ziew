const builtin = @import("builtin");
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
var g_bss: [0x4000 - 0x580 - 64 - 0x40]u8 align(64) = undefined;

// USR1 signal latch.
var g_refresh_all = false;

const WRITE_FAIL_CHECK = true;

const I3BAR_HEADER = "{\"version\":1}\n[[]";

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
    mem: w_mem.State = undefined,
    cpu: w_cpu.State = undefined,
    disk: w_dysk.State = undefined,
    net: w_net.State = .empty,
};

fn fatalConfig(diag: cfg.ParseResult.Diagnostic) noreturn {
    @branchHint(.cold);

    const pad: [7]u8 = @splat(' ');
    var writer: uio.Writer = .fixed(&g_bss);

    var cur = writer.end;
    const note = blk: {
        uio.writeStr(&writer, "fatal: config: ");
        uio.writeStr(&writer, diag.note);
        break :blk writer.buffered()[cur..];
    };

    cur = writer.end;
    const diag_line = blk: {
        const n = ustr.unsafeU64toa(&g_bss, diag.line_nr);
        uio.writeStr(&writer, g_bss[g_bss.len - n ..]);
        uio.writeStr(&writer, pad[0..pad.len -| n]);
        uio.writeStr(&writer, diag.line);
        break :blk writer.buffered()[cur..];
    };

    cur = writer.end;
    const diag_beg, const diag_end = .{ diag.field.beg, diag.field.end };
    const underline = blk: {
        if (diag_beg < diag_end) {
            uio.writeStr(&writer, &pad);
            uio.writeCh(&writer, ' ', diag_beg);
            uio.writeCh(&writer, '~', diag_end - diag_beg);
            break :blk writer.buffered()[cur..];
        }
        break :blk "";
    };

    const l: log.Log = .open(.file);
    l.log(note);
    l.log("\n");
    l.log(diag_line);
    l.log("\n");
    l.log(underline);
    l.log("\n");
    l.close();

    cur = writer.end;
    const diag_line_marked = blk: {
        if (underline.len > 0) {
            uio.writeStr(&writer, diag_line[0..pad.len]);
            uio.writeStr(&writer, diag.line[0..diag_beg]);
            uio.writeStr(&writer, ">>");
            uio.writeStr(&writer, diag.line[diag_beg..diag_end]);
            uio.writeStr(&writer, "<<");
            uio.writeStr(&writer, diag.line[diag_end..]);
            break :blk writer.buffered()[cur..];
        }
        break :blk "";
    };

    cur = writer.end;
    typ.writeWidgetBeg(&writer, .init(.fg, "ff4444".*), .empty);
    uio.writeStr(&writer, note);
    uio.writeStr(&writer, ": ");
    uio.writeStr(&writer, diag_line_marked);
    const final = typ.writeWidgetEnd(writer.buffer[cur..], writer.end - cur);
    const r = copy(&g_bss, &.{final});

    _ = uio.sys_write(1, I3BAR_HEADER);
    while (true) _ = write(r) or sleep(.{ .sec = @intCast(cur), .nsec = undefined });

    unreachable;
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

const ConfigPathError = error{NoPath} || umem.Region.Error;
const ConfigPathResult = struct { [*:0]const u8, umem.Region.SavePoint };

fn getConfigPath(reg: *umem.Region) ConfigPathError!ConfigPathResult {
    const sp = reg.save(u8, .front);
    var n: usize = 0;

    if (std.c.getenv("XDG_CONFIG_HOME")) |ok| {
        n += (try reg.writeStr(mem.sliceTo(ok, 0), .front)).len;
        n += (try reg.writeStr("/ziew/config\x00", .front)).len;
    } else if (std.c.getenv("HOME")) |ok| {
        n += (try reg.writeStr(mem.sliceTo(ok, 0), .front)).len;
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
    var intrvl: [4]typ.DeciSec = @splat(typ.WIDGET_INTERVAL_MAX);
    var inited: [4]bool = @splat(false);

    const Fn = struct {
        fn index(id: typ.Widget.Id) usize {
            return @intFromEnum(id) -% 1;
        }
        comptime {
            std.debug.assert(index(typ.Widget.Id.MEM) == 0);
            std.debug.assert(index(typ.Widget.Id.CPU) == 1);
            std.debug.assert(index(typ.Widget.Id.DISK) == 2);
            std.debug.assert(index(typ.Widget.Id.NET) == 3);
        }
    };

    for (widgets) |*w| switch (w.id) {
        .MEM, .CPU, .DISK, .NET => {
            const id = Fn.index(w.id);

            if (!inited[id]) {
                switch (w.id) {
                    .MEM => states.mem = .init(),
                    .CPU => states.cpu = try .init(reg, widgets),
                    .DISK => states.disk = try .init(reg, widgets),
                    .NET => states.net = .init(widgets, reg.head.ptr),
                    else => unreachable,
                }
                inited[id] = true;
            }
            // DISK widgets perform per mountpoint updates,
            // no need to clamp the interval.
            switch (w.id) {
                .MEM, .CPU, .NET => intrvl[id] = @min(intrvl[id], w.interval.set),
                else => {},
            }
        },
        else => {},
    };
    for (widgets) |*w| switch (w.id) {
        .MEM, .CPU, .NET => w.interval.set = intrvl[Fn.index(w.id)],
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

fn write(buf: []const u8) bool {
    while (true) {
        const ret = uio.sys_write(1, buf);
        if (ret >= 0) return false;
        if (ret == -ext.c.EINTR) {
            if (g_refresh_all) return true;
        } else if (WRITE_FAIL_CHECK) {
            log.fatalSys(&.{"main: write: "}, ret);
        }
    }
}

fn sleep(ts: linux.timespec) bool {
    var req = ts;
    while (true) {
        if (linux.nanosleep(&req, &req) == 0) return false;
        // Only EINTR is reachable here.
        if (g_refresh_all) return true;
    }
}

comptime {
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}
pub fn main(argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int {
    errdefer log.fatal(&.{"main exited"});

    var reg: umem.Region = .init(&g_bss, "main");

    const args: Args = .read(argv[0..@intCast(argc)]);
    const widgets = loadConfig(&reg, args.config_path);

    setupSignals();

    const sleep_dsec = sleepInterval(widgets);
    const sleep_ts: linux.timespec = .{
        .sec = @divTrunc(sleep_dsec, 10),
        .nsec = @rem(sleep_dsec, 10) * (time.ns_per_s / 10),
    };

    var states: WidgetStates = .{};
    try setupWidgets(&reg, widgets, &states);

    const vecs = try reg.allocMany([]const u8, widgets.len, .front);
    const bufs = try reg.allocMany([typ.WIDGET_BUF_MAX]u8, widgets.len, .front);

    const base = reg.head.ptr;

    _ = uio.sys_write(1, I3BAR_HEADER);
    refresh: while (true) {
        if (g_refresh_all) {
            @branchHint(.unlikely);
            for (widgets) |*w| w.interval.now = 0;
            g_refresh_all = false;
        }
        try update(&reg, widgets, &states, bufs, vecs, sleep_dsec);
        const r = copy(base[reg.front..reg.back], vecs);
        if (write(r) or sleep(sleep_ts)) continue :refresh;
    }
    unreachable;
}

test "all tests" {
    _ = @import("config.zig");
    _ = @import("w_mem.zig");
    _ = @import("w_cpu.zig");
    _ = @import("w_net.zig");
}
