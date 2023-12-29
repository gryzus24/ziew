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
const mem = std.mem;
const time = std.time;

fn debugCF(cf: *const cfg.ConfigFormat) void {
    for (cf.formats) |format| {
        std.debug.print("PARTS: ", .{});
        for (format.parts) |part| {
            std.debug.print("[{s}]  ", .{part});
        }
        std.debug.print("\n", .{});
        std.debug.print("OPTS:  ", .{});
        for (format.opts) |opt| {
            std.debug.print("{d} ", .{opt});
        }
        std.debug.print("\n", .{});
        std.debug.print("PRECI: {any}\n", .{format.opts_precision});
        std.debug.print("ALIGN: {any}\n", .{format.opts_alignment});
        std.debug.print("======\n", .{});
    }
    std.debug.print("INTERVALS: ", .{});
    for (cf.intervals) |intrvl| {
        std.debug.print("{d} ", .{intrvl});
    }
    std.debug.print("\n", .{});
}

fn debugCC(config: *const cfg.Config) void {
    std.debug.print("FG COLORS:\n", .{});
    for (config.wid_fgs) |elem| {
        std.debug.print(" OPT:   {any}\n", .{elem.opt});
        std.debug.print(" NCOLS: {}\n", .{elem.colors.len});
        for (elem.colors) |color| {
            std.debug.print("  {any}\n", .{color});
        }
    }
    std.debug.print("\n", .{});
    std.debug.print("BG COLORS:\n", .{});
    for (config.wid_bgs) |elem| {
        std.debug.print(" OPT:   {any}\n", .{elem.opt});
        std.debug.print(" NCOLS: {}\n", .{elem.colors.len});
        for (elem.colors) |color| {
            std.debug.print("  {any}\n", .{color});
        }
    }
    std.debug.print("\n", .{});
}

fn openProcFiles(dest: *[typ.WIDGETS_MAX]fs.File, widgets: []const cfg.Widget) void {
    const wid_to_path = blk: {
        var w: [typ.WIDGETS_MAX][:0]const u8 = .{""} ** typ.WIDGETS_MAX;
        w[@intFromEnum(typ.WidgetId.MEM)] = "/proc/meminfo";
        w[@intFromEnum(typ.WidgetId.CPU)] = "/proc/stat";
        break :blk w;
    };

    for (widgets) |*widget| {
        const wid = @intFromEnum(widget.wid);
        const path = wid_to_path[wid];
        if (path.len > 0) {
            dest[wid] = fs.cwd().openFileZ(path, .{}) catch |err| {
                utl.fatal("{s} open: {}", .{ path, err });
            };
        }
    }
}

fn showHelp() void {
    utl.writeStr(io.getStdOut(), "usage: ziew [c <config file>] [h] [v]\n");
}

fn showVersion() void {
    utl.writeStr(io.getStdOut(), "ziew 0.0.1\n");
}

pub fn main() void {
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
                'h' => return showHelp(),
                'v' => return showVersion(),
                else => {
                    utl.writeStr(io.getStdOut(), "unknown option\n");
                    return showHelp();
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
            return showHelp();
        }
    }

    var _config_buf: [cfg.CONFIG_FILE_BYTES_MAX]u8 = undefined;
    var _config_mem: cfg.ConfigMem = undefined;
    var config: cfg.Config = undefined;

    const err = blk: {
        if (cfg.readFile(&_config_buf, config_path)) |config_file_view| {
            config = cfg.parse(config_file_view, &_config_mem);
            if (config.widgets.len == 0) {
                utl.warn("no widgets loaded: using defaults...", .{});
                break :blk true;
            } else {
                break :blk false;
            }
        } else |err| switch (err) {
            error.FileNotFound => {
                utl.warn("no config file: using defaults...", .{});
                break :blk true;
            },
        }
    };
    if (err)
        config = cfg.defaultConfig(&_config_mem);

    const sleep_intrvl = blk: {
        // NOTE: gcd is the obvious choice here, but it might prove
        //       disastrous if the interval is misconfigured...
        var min = config.widgets[0].interval;
        for (config.widgets[1..]) |*widget| if (widget.interval < min) {
            min = widget.interval;
        };
        break :blk min;
    };
    const sleep_s = sleep_intrvl / 10;
    const sleep_ns = (sleep_intrvl % 10) * time.ns_per_s / 10;

    const wid_to_procfile = blk: {
        var buf: [typ.WIDGETS_MAX]fs.File = undefined;
        openProcFiles(&buf, config.widgets);
        break :blk buf;
    };

    const strftime_fmt: ?[:0]const u8 = blk: {
        var buf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;
        for (config.widgets, config.formats) |*widget, f| {
            if (widget.wid == typ.WidgetId.TIME) {
                const plen = f.parts[0].len;
                if (plen >= buf.len)
                    utl.fatal("strftime format too long", .{});

                @memcpy(buf[0..plen], f.parts[0]);
                buf[plen] = '\x00';
                break :blk buf[0..plen :0];
            }
        }
        break :blk null;
    };

    const has_battery = blk: {
        for (config.widgets) |*widget| {
            if (widget.wid == typ.WidgetId.BAT)
                break :blk w_bat.hasBattery();
        }
        break :blk false;
    };

    var _timebuf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;
    var _membuf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;
    var _cpubuf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;
    var _diskbuf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;
    var _ethbuf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;
    var _wlanbuf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;
    var _batbuf: [typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;

    var timefbs = io.fixedBufferStream(&_timebuf);
    var memfbs = io.fixedBufferStream(&_membuf);
    var cpufbs = io.fixedBufferStream(&_cpubuf);
    var diskfbs = io.fixedBufferStream(&_diskbuf);
    var ethfbs = io.fixedBufferStream(&_ethbuf);
    var wlanfbs = io.fixedBufferStream(&_wlanbuf);
    var batfbs = io.fixedBufferStream(&_batbuf);

    var bufviews: [typ.WIDGETS_MAX][]const u8 = undefined;
    var write_buffer: [2 + typ.WIDGETS_MAX * typ.WIDGET_BUF_BYTES_MAX]u8 = undefined;

    write_buffer[0] = ',';
    write_buffer[1] = '[';

    var cpu_state: w_cpu.ProcStat = .{ .fields = .{0} ** 10 };
    var refresh_lags: [typ.WIDGETS_MAX]typ.DeciSec = .{0} ** typ.WIDGETS_MAX;

    const header =
        \\{"version":1}
        \\[[]
    ;
    _ = linux.write(1, header, header.len);
    while (true) {
        for (config.widgets, config.formats, 0..) |*widget, format, i| {
            refresh_lags[i] -|= sleep_intrvl;
            if (refresh_lags[i] == 0) {
                refresh_lags[i] = widget.interval;

                const fg = &widget.fgcu;
                const bg = &widget.bgcu;
                const pf = &wid_to_procfile[@intFromEnum(widget.wid)];

                bufviews[i] = switch (widget.wid) {
                    .TIME => w_time.widget(&timefbs, strftime_fmt.?, fg, bg),
                    .MEM => w_mem.widget(&memfbs, pf, &format, fg, bg),
                    .CPU => w_cpu.widget(&cpufbs, pf, &cpu_state, &format, fg, bg),
                    .DISK => w_dysk.widget(&diskfbs, &format, fg, bg),
                    .ETH => w_net.widget(&ethfbs, &format, fg, bg),
                    .WLAN => w_net.widget(&wlanfbs, &format, fg, bg),
                    .BAT => if (has_battery)
                        w_bat.widget(&batfbs, &format, fg, bg)
                    else
                        w_bat.widget_no_battery(&batfbs),
                };
            }
        }

        var pos: usize = 2;
        for (bufviews[0..config.widgets.len]) |view| {
            @memcpy(write_buffer[pos .. pos + view.len], view);
            pos += view.len;
        }
        // get rid of the trailing comma
        write_buffer[pos - 1] = ']';

        _ = linux.write(1, &write_buffer, pos);
        std.os.nanosleep(sleep_s, sleep_ns);
    }

    unreachable;
}
