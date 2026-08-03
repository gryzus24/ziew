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
const meta = std.meta;
const process = std.process;
const time = std.time;

// This is all dynamic memory available to the program.
// Four 4K pages minus some fiddle with BSS, DATA, and alignment,
// packing everything tightly to avoid internal fragmentation.
var g_bss: [4 * typ.PAGE - 0x600 - 64]u8 align(64) = undefined;

// USR1 signal latch.
var g_refresh_all = false;

const I3BAR_HEADER = "{\"version\":1}\n[[]";

const WidgetSeq = []const typ.Widget;

fn Embed(comptime prefix: []const u8) type {
    return struct {
        const widgets_len = embedWidgets().len;

        fn __embed(comptime suffix: []const u8, comptime RetType: type) RetType {
            const a = @embedFile(prefix ++ "." ++ suffix);
            const a_aligned: [a.len]u8 align(@alignOf(meta.Child(RetType))) = a.*;
            return @ptrCast(&a_aligned);
        }

        fn embedWidgets() WidgetSeq {
            return __embed("widgets", WidgetSeq);
        }
        fn embedData() []const u8 {
            return __embed("data", []const u8);
        }
        fn embedIntervals() *const [widgets_len]typ.DeciSec {
            return __embed("intervals", *const [widgets_len]typ.DeciSec);
        }
        fn embedWidgetIds() *const [widgets_len]typ.Widget.Id {
            return __embed("widget_ids", *const [widgets_len]typ.Widget.Id);
        }
    };
}

const CONFIG: ?type =
    if (@import("config").is_embedding_config)
        Embed("config")
    else
        null;

const __widgets_present: [typ.Widget.NR_WIDGETS]bool = blk: {
    if (CONFIG) |ok| {
        var present: [typ.Widget.NR_WIDGETS]bool = @splat(false);
        for (ok.embedWidgetIds()) |wid|
            present[@intFromEnum(wid)] = true;
        break :blk present;
    }
    break :blk @splat(true);
};

inline fn hasWid(comptime wid: typ.Widget.Id) bool {
    return __widgets_present[@intFromEnum(wid)];
}

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
            .v => _ = uio.sys_write(2, "ziew 0.0.14\n"),
        }
        linux.exit(0);
    }
};

pub const WidgetStates = struct {
    mem: if (hasWid(.MEM)) w_mem.State else void,
    cpu: if (hasWid(.CPU)) w_cpu.State else void,
    disk: if (hasWid(.DISK)) w_dysk.State else void,
    net: if (hasWid(.NET)) w_net.State else void,

    pub const empty: WidgetStates = .{
        .mem = undefined,
        .cpu = undefined,
        .disk = undefined,
        .net = if (hasWid(.NET)) .empty else undefined,
    };
};

fn fatalConfig(diag: cfg.ParseResult.Diagnostic) noreturn {
    @branchHint(.cold);

    const pad: [7]u8 = @splat(' ');
    var writer: uio.Writer = .fixed(&g_bss);

    const note = blk: {
        uio.writeStr(&writer, "fatal: config: ");
        uio.writeStr(&writer, diag.note);
        break :blk writer.gobble();
    };

    const diag_line = blk: {
        const n = ustr.unsafeU64toa(&g_bss, diag.line_nr);
        uio.writeStr(&writer, g_bss[g_bss.len - n ..]);
        uio.writeStr(&writer, pad[0..pad.len -| n]);
        uio.writeStr(&writer, diag.line);
        break :blk writer.gobble();
    };

    const diag_beg, const diag_end = .{ diag.field.beg, diag.field.end };
    const underline = blk: {
        if (diag_beg < diag_end) {
            uio.writeStr(&writer, &pad);
            uio.writeCh(&writer, ' ', diag_beg);
            uio.writeCh(&writer, '~', diag_end - diag_beg);
            break :blk writer.gobble();
        }
        break :blk "";
    };

    log.logStrings(.file, null, &.{ note, "\n", diag_line, "\n", underline }, "\n");

    const diag_line_marked = blk: {
        if (underline.len > 0) {
            uio.writeStr(&writer, diag_line[0..pad.len]);
            uio.writeStr(&writer, diag.line[0..diag_beg]);
            uio.writeStr(&writer, ">>");
            uio.writeStr(&writer, diag.line[diag_beg..diag_end]);
            uio.writeStr(&writer, "<<");
            uio.writeStr(&writer, diag.line[diag_end..]);
            break :blk writer.gobble();
        }
        break :blk "";
    };

    const beg = writer.end;
    typ.writeWidgetBeg(&writer, .init(.fg, "ff4444".*), .empty);
    uio.writeStr(&writer, note);
    uio.writeStr(&writer, ": ");
    uio.writeStr(&writer, diag_line_marked);
    const final = typ.writeWidgetEnd(writer.buffer[beg..], writer.end - beg);
    const r = copy(&g_bss, &.{final});

    _ = uio.sys_write(1, I3BAR_HEADER);
    while (true) _ = write(r) or sleep(.{ .sec = 5, .nsec = undefined });

    unreachable;
}

fn defaultConfig(reg: *umem.Region) WidgetSeq {
    const c = Embed("default-config");
    _ = reg.writeStr(c.embedData(), .front) catch unreachable;
    return c.embedWidgets();
}

fn loadConfig(reg: *umem.Region, config_path: ?[:0]const u8) WidgetSeq {
    const fd = blk: {
        var path: [:0]const u8 = undefined;
        if (config_path) |ok| {
            path = ok;
        } else {
            path, const path_sp = getConfigPath(reg) catch |e| switch (e) {
                error.NoPath => {
                    log.warn(&.{"config: unknown path: using default config"});
                    return defaultConfig(reg);
                },
                error.NoSpaceLeft => log.fatal(&.{"config: path too long"}),
            };
            // We can mark it as free immediately, as the path is referenced
            // by open0 and possibly by log.warn inside the "fd blk", but it
            // can't be overwritten in between.
            reg.restore(path_sp);
        }
        break :blk uio.open0(path) catch |e| switch (e) {
            error.FileNotFound, error.AccessDenied => {
                log.warn(&.{ "config: ", @errorName(e), ": ", path });
                log.warn(&.{"using default config"});
                return defaultConfig(reg);
            },
            else => log.fatal(&.{ "config: open: ", @errorName(e) }),
        };
    };
    defer uio.close(fd);

    const parse_bentry = reg.save(u8, .back);
    defer reg.restore(parse_bentry);

    const filebuf, const scratch = typ.allocConfigParserMem(reg);
    var bf: uio.BufferedFile = .init(fd, filebuf);

    const ret = cfg.parse(reg, &bf.buffer, scratch) catch |e| switch (e) {
        error.NoSpaceLeft,
        error.LineTooLong,
        error.ReadError,
        => log.fatal(&.{ "config: ", @errorName(e) }),
    };
    const widgets = switch (ret) {
        .ok => |w| w,
        .err => |diag| fatalConfig(diag),
    };

    if (widgets.len == 0) {
        log.warn(&.{"config: no widgets loaded: using default config"});
        return defaultConfig(reg);
    }
    return widgets;
}

const ConfigPathError = error{NoPath} || umem.Region.Error;
const ConfigPathResult = struct { [:0]const u8, umem.Region.SavePoint };

fn getConfigPath(reg: *umem.Region) ConfigPathError!ConfigPathResult {
    const keys: [2][:0]const u8 =
        .{ "XDG_CONFIG_HOME", "HOME" };
    const suffixa: [2][:0]const u8 =
        .{ "/ziew/config\x00", "/.config/ziew/config\x00" };

    for (keys, suffixa) |key, suffix| {
        if (std.c.getenv(key)) |ok| {
            const prefix = mem.sliceTo(ok, 0);
            const sp = reg.save(u8, .front);
            const path = try reg.allocMany(u8, prefix.len + suffix.len, .front);
            uio.memcpyMany(path, .{ prefix, suffix });
            return .{ path[0 .. path.len - 1 :0], sp };
        }
    }
    log.warn(&.{"neither $HOME nor $XDG_CONFIG_HOME set!"});
    return error.NoPath;
}

fn sa_handler(signum: linux.SIG) callconv(.c) void {
    if (signum == linux.SIG.USR1) g_refresh_all = true;
}

fn setupSignals() !void {
    const action: linux.Sigaction = .{
        .handler = .{ .handler = &sa_handler },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    if (linux.sigaction(linux.SIG.USR1, &action, null) != 0)
        return error.Sigaction;
}

fn sleepInterval(intervals: []const typ.UDeciSec) typ.DeciSec {
    var min: typ.UDeciSec = typ.WIDGET_INTERVAL_MAX;
    var gcd: typ.UDeciSec = 0;

    for (intervals) |interval| {
        // Intervals of `WIDGET_INTERVAL_MAX` are treated as "refresh once and forget".
        if (interval != typ.WIDGET_INTERVAL_MAX) {
            min = @min(min, interval);
            gcd = if (gcd == 0) interval else misc.gcd(gcd, interval);
        }
    }
    if (gcd < min)
        log.warn(&.{"GCD of intervals < shortest interval, widget updates will be inexact"});

    // NOTE: gcd is the obvious choice here, but it might prove
    //       disastrous if the interval is misconfigured...
    return @intCast(min);
}

inline fn windex(wid: typ.Widget.Id) u32 {
    return @intFromEnum(wid) -% 1;
}
inline fn wbit(wid: typ.Widget.Id) u32 {
    return @as(u32, 1) << @intCast(windex(wid));
}
comptime {
    std.debug.assert(windex(typ.Widget.Id.MEM) == 0);
    std.debug.assert(windex(typ.Widget.Id.CPU) == 1);
    std.debug.assert(windex(typ.Widget.Id.DISK) == 2);
    std.debug.assert(windex(typ.Widget.Id.NET) == 3);
}

fn setupWidgets(reg: *umem.Region, widgets: WidgetSeq, states: *WidgetStates) !void {
    const base = reg.head.ptr;

    var initialize: u32 = 0;
    var intervals: [4]typ.DeciSec = @splat(typ.WIDGET_INTERVAL_MAX);

    for (widgets) |*w| switch (w.id) {
        .MEM, .CPU, .DISK, .NET => {
            const id = windex(w.id);
            initialize |= wbit(w.id);
            intervals[id] = @min(intervals[id], w.readInterval(base).set);
        },
        else => {},
    };
    if (hasWid(.MEM) and wbit(.MEM) & initialize != 0)
        states.mem = try .init();
    if (hasWid(.CPU) and wbit(.CPU) & initialize != 0)
        states.cpu = try .init(reg, widgets);
    if (hasWid(.DISK) and wbit(.DISK) & initialize != 0)
        states.disk = try .init(reg, widgets);
    if (hasWid(.NET) and wbit(.NET) & initialize != 0)
        states.net = try .init(widgets, base);

    // DISK widgets perform per mountpoint updates - no need to clamp the interval.
    for (widgets) |*w| switch (w.id) {
        .MEM, .CPU, .NET => w.getInterval(base).set = intervals[windex(w.id)],
        else => {},
    };
}

fn update(
    reg: *umem.Region,
    widgets: WidgetSeq,
    states: *WidgetStates,
    bufs: [][typ.WIDGET_BUF_MAX]u8,
    vecs: [][]const u8,
    sleep_dsec: typ.DeciSec,
) !void {
    const base = reg.head.ptr;

    var updated: packed struct(u32) {
        net: bool = false,
        mem: bool = false,
        cpu: bool = false,
        _: u29 = 0,
    } = .{};
    if (hasWid(.NET))
        updated.net = states.net.netdev == null;

    for (widgets, 0..) |*w, i| {
        const interval = w.getInterval(base);
        interval.now -= sleep_dsec;
        if (interval.now <= 0) {
            var fw: uio.Writer = .fixed(bufs[i][0..typ.WIDGET_BUF_WRITABLE]);
            const parts = w.format.parts.get(base);
            switch (w.id) {
                .TIME => if (hasWid(.TIME))
                    w_time.widget(&fw, w, parts, base),
                .MEM => if (hasWid(.MEM)) {
                    if (!updated.mem) {
                        try w_mem.update(&states.mem);
                        updated.mem = true;
                    }
                    w_mem.widget(&fw, w, parts, base, &states.mem);
                },
                .CPU => if (hasWid(.CPU)) {
                    if (!updated.cpu) {
                        try w_cpu.update(&states.cpu);
                        updated.cpu = true;
                    }
                    w_cpu.widget(&fw, w, parts, base, &states.cpu);
                },
                .DISK => if (hasWid(.DISK))
                    w_dysk.widget(&fw, w, parts, base, &states.disk),
                .NET => if (hasWid(.NET)) {
                    if (!updated.net) {
                        try w_net.update(reg, &states.net.netdev.?);
                        updated.net = true;
                    }
                    w_net.widget(&fw, w, parts, base, &states.net);
                },
                .BAT => if (hasWid(.BAT))
                    w_bat.widget(&fw, w, parts, base),
                .READ => if (hasWid(.READ))
                    w_read.widget(&fw, w, parts, base),
            }
            w.format.last_str.writeBytes(&fw, base);
            vecs[i] = typ.writeWidgetEnd(&bufs[i], fw.end);
            interval.now = interval.set;
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
        } else if (true) {
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

    try setupSignals();

    var reg: umem.Region = blk: {
        if (CONFIG) |_| {
            var stack: [g_bss.len]u8 align(16) = undefined;
            break :blk .init(&stack, "main");
        }
        break :blk .init(&g_bss, "main");
    };
    const widgets = blk: {
        if (CONFIG) |ok| {
            _ = try reg.writeStr(ok.embedData(), .front);
            break :blk ok.embedWidgets();
        }
        const args: Args = .read(argv[0..@intCast(argc)]);
        break :blk loadConfig(&reg, mem.sliceTo(args.config_path, 0));
    };
    const base = reg.head.ptr;

    const sleep_dsec = blk: {
        if (CONFIG) |ok| {
            break :blk comptime sleepInterval(@ptrCast(ok.embedIntervals()));
        }
        const sp = reg.save(typ.DeciSec, .front);
        var intervals = try reg.allocMany(typ.DeciSec, widgets.len, .front);
        reg.restore(sp);

        for (widgets, 0..) |*w, i| {
            intervals[i] = @intCast(w.readInterval(base).set);
        }
        break :blk sleepInterval(@ptrCast(intervals));
    };
    const sleep_ts: linux.timespec = .{
        .sec = @divTrunc(sleep_dsec, 10),
        .nsec = @rem(sleep_dsec, 10) * (time.ns_per_s / 10),
    };

    var states: WidgetStates = .empty;
    try setupWidgets(&reg, widgets, &states);

    const vecs = try reg.allocMany([]const u8, widgets.len, .front);
    const bufs = try reg.allocMany([typ.WIDGET_BUF_MAX]u8, widgets.len, .front);

    _ = uio.sys_write(1, I3BAR_HEADER);
    refresh: while (true) {
        if (g_refresh_all) {
            @branchHint(.unlikely);
            for (widgets) |*w| w.getInterval(base).now = 0;
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
