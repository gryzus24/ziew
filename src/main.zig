const std = @import("std");
const cfg = @import("config.zig");
const w_bat = @import("w_bat.zig");
const w_cpu = @import("w_cpu.zig");
const w_dysk = @import("w_dysk.zig");
const w_mem = @import("w_mem.zig");
const w_net = @import("w_net.zig");
const w_time = @import("w_time.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const linux = std.os.linux;
const math = std.math;
const mem = std.mem;
const time = std.time;

fn debugColors(cm: *const cfg.ConfigMem) void {
    const print = std.debug.print;
    print("WIDGETS\n", .{});
    for (cm.widgets) |w| {
        print(" WID: {any}\n", .{w.wid});
        print("  FG: {any}\n", .{w.fg});
        print("  BG: {any}\n", .{w.bg});
    }
    print("NCOLORS: {d}\n", .{cm._ncolors});
    print("COLORS:\n", .{});
    for (cm.colors) |color| {
        print(" {any}\n", .{color});
    }
}

const ProcFiles = struct {
    meminfo: ?fs.File,
    stat: ?fs.File,

    pub fn init(widgets: []const cfg.Widget) ProcFiles {
        var meminfo: ?fs.File = null;
        var stat: ?fs.File = null;
        for (widgets) |*w| {
            if (w.wid == typ.WidgetId.MEM and meminfo == null) {
                meminfo = fs.cwd().openFileZ("/proc/meminfo", .{}) catch |err| {
                    utl.fatal(
                        &.{ "open: /proc/meminfo: ", @errorName(err) },
                    );
                };
            } else if (w.wid == typ.WidgetId.CPU and stat == null) {
                stat = fs.cwd().openFileZ("/proc/stat", .{}) catch |err| {
                    utl.fatal(
                        &.{ "open: /proc/stat: ", @errorName(err) },
                    );
                };
            }
        }
        return .{ .meminfo = meminfo, .stat = stat };
    }
};

fn showHelpAndExit() noreturn {
    utl.writeStr(io.getStdOut(), "usage: ziew [c <config file>] [h] [v]\n");
    std.os.exit(0);
}

fn showVersionAndExit() noreturn {
    utl.writeStr(io.getStdOut(), "ziew 0.0.2\n");
    std.os.exit(0);
}

fn readArgs() ?[*:0]const u8 {
    const argv = std.os.argv;

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
                'h' => showHelpAndExit(),
                'v' => showVersionAndExit(),
                else => {
                    utl.writeStr(io.getStdOut(), "unknown option\n");
                    showHelpAndExit();
                },
            }
        }
        if (argi < argv.len) {
            if (get_config_path) {
                config_path = argv[argi];
                get_config_path = false;
            }
        } else {
            const stdout = io.getStdOut();
            utl.writeStr(stdout, "required argument: ");
            utl.writeStr(stdout, arg[0..len]);
            utl.writeStr(stdout, " <arg>\n");
            showHelpAndExit();
        }
    }
    return config_path;
}

fn readConfig(
    buf: *[typ.CONFIG_FILE_BUF_MAX]u8,
    cm: *cfg.ConfigMem,
    path: ?[*:0]const u8,
) []const cfg.Widget {
    var widgets: []const cfg.Widget = undefined;

    const err = blk: {
        if (cfg.readFile(buf, path)) |config_view| {
            widgets = cfg.parse(cm, config_view);
            if (widgets.len == 0) {
                utl.warn(&.{"no widgets loaded: using defaults..."});
                break :blk true;
            } else {
                break :blk false;
            }
        } else |err| switch (err) {
            error.FileNotFound => {
                utl.warn(&.{"no config file: using defaults..."});
                break :blk true;
            },
        }
    };
    if (err)
        widgets = cfg.defaultConfig(cm);

    return widgets;
}

fn minSleepInterval(widgets: []const cfg.Widget) typ.DeciSec {
    var min = widgets[0].interval;
    var gcd = min;
    for (widgets[1..]) |*w| {
        if (w.interval < min) min = w.interval;
        gcd = math.gcd(gcd, w.interval);
    }
    if (gcd < min) utl.warn(
        &.{"gcd of intervals < minimum interval, widget refreshes will be inexact"},
    );
    // NOTE: gcd is the obvious choice here, but it might prove
    //       disastrous if the interval is misconfigured...
    return min;
}

fn zeroStrftimeFormat(
    buf: *[typ.WIDGET_BUF_MAX / 2]u8,
    widgets: []const cfg.Widget,
) ?[*:0]const u8 {
    for (widgets) |*w| {
        if (w.wid == typ.WidgetId.TIME) {
            return utl.zeroTerminate(buf, w.format.parts[0]) orelse utl.fatal(
                &.{"time format too long"},
            );
        }
    }
    return null;
}

pub fn main() void {
    var _config_buf: [typ.CONFIG_FILE_BUF_MAX]u8 = undefined;
    var _config_mem: cfg.ConfigMem = .{};

    const config_path = readArgs();
    const widgets = readConfig(&_config_buf, &_config_mem, config_path);

    const sleep_interval = minSleepInterval(widgets);
    const sleep_s = sleep_interval / 10;
    const sleep_ns = (sleep_interval % 10) * time.ns_per_s / 10;

    var strftime_fmt_buf: [typ.WIDGET_BUF_MAX / 2]u8 = undefined;
    const strftime_fmt = zeroStrftimeFormat(&strftime_fmt_buf, widgets);

    const procfiles = ProcFiles.init(widgets);

    var writebuf: [2 + typ.WIDGETS_MAX * typ.WIDGET_BUF_MAX]u8 = undefined;
    var widgetbuf: [typ.WIDGETS_MAX * typ.WIDGET_BUF_MAX]u8 = undefined;
    var widgetbuf_views: [typ.WIDGETS_MAX][]const u8 = undefined;

    writebuf[0] = ',';
    writebuf[1] = '[';

    var time_to_refresh: [typ.WIDGETS_MAX]typ.DeciSec = .{0} ** typ.WIDGETS_MAX;

    var cpu_state: w_cpu.CpuState = .{};
    var mem_state: w_mem.MemState = .{};

    const header =
        \\{"version":1}
        \\[[]
    ;
    _ = linux.write(1, header, header.len);
    while (true) {
        var cpu_updated = false;
        var mem_updated = false;

        for (widgets, 0..) |*w, i| {
            time_to_refresh[i] -|= sleep_interval;
            if (time_to_refresh[i] == 0) {
                time_to_refresh[i] = w.interval;

                if (w.wid == .CPU and !cpu_updated) {
                    w_cpu.update(&procfiles.stat.?, &cpu_state);
                    cpu_updated = true;
                }
                if (w.wid == .MEM and !mem_updated) {
                    w_mem.update(&procfiles.meminfo.?, &mem_state);
                    mem_updated = true;
                }

                const start = 2 + i * typ.WIDGET_BUF_MAX;
                var fbs = io.fixedBufferStream(
                    widgetbuf[start .. start + typ.WIDGET_BUF_MAX],
                );

                widgetbuf_views[i] = switch (w.wid) {
                    .TIME => w_time.widget(&fbs, strftime_fmt.?, &w.fg, &w.bg),
                    .MEM => w_mem.widget(&fbs, &mem_state, w.format, &w.fg, &w.bg),
                    .CPU => w_cpu.widget(&fbs, &cpu_state, w.format, &w.fg, &w.bg),
                    .DISK => w_dysk.widget(&fbs, w.format, &w.fg, &w.bg),
                    .NET => w_net.widget(&fbs, w.format, &w.fg, &w.bg),
                    .BAT => w_bat.widget(&fbs, w.format, &w.fg, &w.bg),
                };
            }
        }

        var pos: usize = 2;
        for (widgetbuf_views[0..widgets.len]) |view| {
            @memcpy(writebuf[pos .. pos + view.len], view);
            pos += view.len;
        }
        // get rid of the trailing comma
        writebuf[pos - 1] = ']';

        _ = linux.write(1, &writebuf, pos);
        std.os.nanosleep(sleep_s, sleep_ns);
    }

    unreachable;
}
