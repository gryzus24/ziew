const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const os = std.os;

pub const Alignment = enum { none, right, left };

pub const Opt = struct {
    opt: u8,
    precision: u8, // value between 0-9
    alignment: Alignment,
};

// MEM 20 "MEM {used} : {free} +{cached.0}"
//         ^^^^ ~~~~ ^^^ ~~~~ ^^ ~~~~~~~~ ^ (Empty string)
// ^ - part
// ~ - opt
pub const ConfigFormat = struct {
    nparts: u8,
    parts: [*][]const u8,
    opts: [*]Opt,

    pub fn iterParts(self: @This()) []const []const u8 {
        return self.parts[0..self.nparts];
    }

    pub fn iterOpts(self: @This()) []const Opt {
        return self.opts[0 .. self.nparts - 1];
    }
};

pub const Widget = struct {
    wid: typ.WidgetId = typ.WidgetId.TIME,
    interval: typ.DeciSec = INTERVAL_DEFAULT,
    fgcu: color.ColorUnion = .{ .nocolor = {} },
    bgcu: color.ColorUnion = .{ .nocolor = {} },
};

pub const ConfigFormatMem = struct {
    parts: [typ.PARTS_MAX][]const u8,
    opts: [typ.OPTS_MAX]Opt,
};

pub const ConfigMem = struct {
    widgets_buf: [typ.WIDGETS_MAX]Widget,
    formats_buf: [typ.WIDGETS_MAX]ConfigFormat,
    formats_mem_buf: [typ.WIDGETS_MAX]ConfigFormatMem,
    fg_colors_buf: [typ.WIDGETS_MAX][COLORS_MAX]color.Color,
    bg_colors_buf: [typ.WIDGETS_MAX][COLORS_MAX]color.Color,
};

pub const Config = struct {
    widgets: []const Widget,
    formats: []const ConfigFormat,
};

pub const CONFIG_FILE_BYTES_MAX = 2048;

fn defaultConfigPath(
    buf: *[CONFIG_FILE_BYTES_MAX]u8,
) error{ FileNotFound, PathTooLong }![*:0]const u8 {
    var fbs = io.fixedBufferStream(buf);
    if (os.getenvZ("XDG_CONFIG_HOME")) |xdg| {
        _ = fbs.write(xdg) catch return error.PathTooLong;
        _ = fbs.write("/ziew/config") catch return error.PathTooLong;
    } else if (os.getenvZ("HOME")) |home| {
        _ = fbs.write(home) catch return error.PathTooLong;
        _ = fbs.write("/.config/ziew/config") catch return error.PathTooLong;
    } else {
        utl.warn("config: $HOME and $XDG_CONFIG_HOME not set", .{});
        return error.FileNotFound;
    }
    _ = fbs.write("\x00") catch return error.PathTooLong;

    const ret = fbs.getWritten();
    return ret[0 .. ret.len - 1 :0];
}

pub fn readFile(
    buf: *[CONFIG_FILE_BYTES_MAX]u8,
    path: ?[*:0]const u8,
) error{FileNotFound}![]const u8 {
    const config_path = path orelse (defaultConfigPath(buf) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.PathTooLong => utl.fatal("config: {}", .{err}),
    });

    const file = fs.cwd().openFileZ(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => utl.fatal("config: open: {}", .{err}),
    };
    defer file.close();

    const nread = nread_blk: {
        var nread = file.read(buf) catch |err|
            utl.fatal("config: read: {}", .{err});
        if (nread < buf.len) {
            // handle missing $'\n' edge case
            buf[nread] = '\n';
            break :nread_blk nread + 1;
        } else {
            const sz = sz_blk: {
                const meta = file.metadata() catch |err|
                    utl.fatal("config: file too big: {}", .{err});
                break :sz_blk meta.size();
            };
            utl.fatal("config: file too big by {} bytes", .{sz - nread});
        }
    };
    return buf[0..nread];
}

pub fn parse(buf: []const u8, config_mem: *ConfigMem) Config {
    var nwidgets: u32 = 0;
    var lines = mem.tokenizeScalar(u8, buf, '\n');
    var seen: [typ.WIDGETS_MAX]bool = .{false} ** typ.WIDGETS_MAX;
    var errpos: usize = 0;

    for (0..typ.WIDGETS_MAX) |i| {
        config_mem.widgets_buf[i] = .{};
    }

    while (lines.next()) |line| {
        if (line[0] == '#') {
            // zig fmt: off
        } else if (
            line.len >= 2
            and (line[0] == 'F' or line[0] == 'B')
            and line[1] == 'G'
        ) {
            // zig fmt: on
            const isfg = line[0] == 'F';
            const fg_colors = &config_mem.fg_colors_buf;
            const bg_colors = &config_mem.bg_colors_buf;

            var wid_int: u8 = undefined;
            const config_color = parseColorLine(
                line,
                &wid_int,
                if (isfg) fg_colors else bg_colors,
                &errpos,
            ) catch |err| {
                utl.fatalPos(
                    "config: {}: {s}",
                    .{ err, line },
                    fmt.count("config: {}: ", .{err}) + errpos,
                );
            };
            for (config_mem.widgets_buf[0..nwidgets]) |*widget| {
                if (@intFromEnum(widget.wid) == wid_int) {
                    if (isfg) {
                        widget.fgcu = config_color;
                    } else {
                        widget.bgcu = config_color;
                    }
                    break;
                }
            }
        } else if (typ.strStartToWidEnum(line)) |wid| {
            const wid_int = @intFromEnum(wid);
            if (!seen[wid_int]) {
                parseWidgetLine(
                    line,
                    wid,
                    nwidgets,
                    config_mem,
                    &errpos,
                ) catch |err| {
                    utl.fatalPos(
                        "config: {}: {s}",
                        .{ err, line },
                        fmt.count("config: {}: ", .{err}) + errpos,
                    );
                };

                seen[wid_int] = true;
                config_mem.widgets_buf[nwidgets].wid = wid;
                typ.knobVerifyArgs(wid, &config_mem.formats_buf[nwidgets]);
                nwidgets += 1;
            }
        } else {
            utl.warn("config: unknown widget: '{s}'", .{line});
        }
    }
    return .{
        .widgets = config_mem.widgets_buf[0..nwidgets],
        .formats = config_mem.formats_buf[0..nwidgets],
    };
}

test "config parse" {
    const t = std.testing;

    var buf =
        \\CPU 0 "{%user}{%sys}"
        \\FG CPU %all 0:fff 10:#999
        \\BG CPU 282828
    ;
    var cm: ConfigMem = undefined;

    var conf = parse(buf, &cm);
    try t.expect(conf.widget_ids.len == 1);
    try t.expect(conf.widget_ids[0] == .CPU);

    try t.expect(conf.intervals.len == 1);
    try t.expect(conf.intervals[0] == INTERVAL_MAX);

    try t.expect(conf.formats.len == 1);
    try t.expect(conf.formats[0].nparts == 3);
    try t.expect(mem.eql(u8, conf.formats[0].parts[0], ""));
    try t.expect(mem.eql(u8, conf.formats[0].parts[1], ""));
    try t.expect(mem.eql(u8, conf.formats[0].parts[2], ""));

    try t.expect(conf.formats[0].opts[0] == @intFromEnum(typ.CpuOpt.@"%user"));
    try t.expect(conf.formats[0].opts[1] == @intFromEnum(typ.CpuOpt.@"%sys"));

    try t.expect(conf.formats[0].opts_precision[0] == OPT_PRECISION_DEFAULT);
    try t.expect(conf.formats[0].opts_precision[1] == OPT_PRECISION_DEFAULT);

    try t.expect(conf.formats[0].opts_alignment[0] == OPT_ALIGNMENT_DEFAULT);
    try t.expect(conf.formats[0].opts_alignment[1] == OPT_ALIGNMENT_DEFAULT);

    switch (conf.wid_fgs[@intFromEnum(typ.WidgetId.CPU)]) {
        .nocolor, .default => return error.TestUnexpectedResult,
        .color => |*w| {
            try t.expect(w.opt == @intFromEnum(typ.CpuOpt.@"%all"));
            try t.expect(w.colors.len == 2);
            try t.expect(w.colors[0].thresh == 0);
            try t.expect(mem.eql(u8, w.colors[0].getHex().?, "#ffffff"));
            try t.expect(w.colors[1].thresh == 10);
            try t.expect(mem.eql(u8, w.colors[1].getHex().?, "#999999"));
        },
    }
    switch (conf.wid_bgs[@intFromEnum(typ.WidgetId.CPU)]) {
        .nocolor, .color => return error.TestUnexpectedResult,
        .default => |*w| {
            try t.expect(w.thresh == 0);
            try t.expect(mem.eql(u8, w.getHex().?, "#282828"));
        },
    }
}

pub fn defaultConfig(config_mem: *ConfigMem) Config {
    const default_config =
        \\ETH  20  "enp5s0{-}{ifname}: {inet} {flags}"
        \\DISK 200 "/{-}/ {available}"
        \\CPU  20  "CPU{%all.1>}"
        \\MEM  20  "MEM {used} : {free} +{cached.0}"
        \\BAT  300 "BAT {%charge.2} {state}"
        \\TIME 20  "%A %d.%m ~ %H:%M:%S "
        \\FG ETH state   0:a44 1:4a4
        \\FG CPU %all    60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\FG MEM %used   60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\FG BAT state   1:4a4 2:4a4
        \\BG BAT %charge 0:a00 15:220 25:
    ;
    return parse(default_config, config_mem);
}

// == private ==

const INTERVAL_DEFAULT: typ.DeciSec = 50;
const INTERVAL_MAX = 1 << (@sizeOf(typ.DeciSec) * 8 - 1);

const OPT_PRECISION_DEFAULT = 1;
const OPT_ALIGNMENT_DEFAULT = .none;

const COLORS_MAX = 10;

fn parseConfigFormat(
    str: []const u8,
    wid: typ.WidgetId,
    format_mem: *ConfigFormatMem,
    errpos: *usize,
) !ConfigFormat {
    var i: usize = 0;
    errdefer errpos.* = i;

    if (str.len == 0)
        return error.NoFormat;
    if (str[0] != '"' or str[str.len - 1] != '"' or str.len == 1)
        return error.MissingQuotes;

    const line = str[1 .. str.len - 1];

    var optbuf: [typ.OPT_NAME_BUF_MAX]u8 = undefined;
    var optbuf_i: usize = 0;

    var nparts: u8 = 0;

    var in: bool = false;
    var pos: usize = 0;
    for (line) |ch| {
        if (in) {
            switch (ch) {
                '}' => {
                    format_mem.opts[nparts - 1].opt = for (
                        typ.WID_TO_OPT_NAMES[@intFromEnum(wid)],
                        0..,
                    ) |name, j| {
                        const end = blk: {
                            if (mem.indexOfScalar(u8, optbuf[0..optbuf_i], '.')) |dot_i| {
                                break :blk dot_i;
                            } else {
                                break :blk optbuf_i;
                            }
                        };

                        if (!mem.eql(u8, name, optbuf[0..end]))
                            continue;

                        // defaults
                        format_mem.opts[nparts - 1].precision = OPT_PRECISION_DEFAULT;
                        format_mem.opts[nparts - 1].alignment = OPT_ALIGNMENT_DEFAULT;

                        // has any specifiers?
                        if (end + 1 < optbuf_i) {
                            for (optbuf[end + 1 .. optbuf_i]) |spec_ch| {
                                switch (spec_ch) {
                                    '0'...'9' => {
                                        format_mem.opts[nparts - 1].precision = spec_ch - '0';
                                    },
                                    '<' => {
                                        format_mem.opts[nparts - 1].alignment = .left;
                                    },
                                    '>' => {
                                        format_mem.opts[nparts - 1].alignment = .right;
                                    },
                                    else => return error.UnknownSpecifier,
                                }
                            }
                        }
                        // set opt to the value of the enum, they all start at 0
                        break @intCast(j);
                    } else {
                        return error.UnknownOption;
                    };
                    optbuf_i = 0;
                    pos = i + 1;
                    in = false;
                },
                '{' => return error.BracketMismatch,
                else => {
                    if (optbuf_i == typ.OPT_NAME_BUF_MAX)
                        return error.UnknownOption;

                    optbuf[optbuf_i] = ch;
                    optbuf_i += 1;
                },
            }
        } else {
            switch (ch) {
                '{' => {
                    in = true;
                    format_mem.parts[nparts] = line[pos..i];
                    nparts += 1;
                    if (nparts == typ.PARTS_MAX)
                        return error.RogueUser;
                },
                '}' => return error.BracketMismatch,
                else => {},
            }
        }
        i += 1;
    }

    if (in)
        return error.BracketMismatch;
    if (nparts == typ.PARTS_MAX)
        return error.RogueUser;

    format_mem.parts[nparts] = line[pos..];
    nparts += 1;

    return .{
        .nparts = nparts,
        .parts = &format_mem.parts,
        .opts = &format_mem.opts,
    };
}

fn intervalFromBuf(buf: []u8) typ.DeciSec {
    const ret = fmt.parseUnsigned(typ.DeciSec, buf, 10) catch unreachable;
    if (ret <= 0 or ret > INTERVAL_MAX) {
        return INTERVAL_MAX;
    } else {
        return ret;
    }
}

fn parseWidgetLine(
    line: []const u8,
    wid: typ.WidgetId,
    windx: u32,
    config_mem: *ConfigMem,
    errpos: *usize,
) !void {
    var pos = @tagName(wid).len;

    var format_errpos: usize = 0;
    errdefer errpos.* = pos + format_errpos;

    if (line.len <= pos)
        return error.NoInterval;
    if (line[pos] != ' ' and line[pos] != '\t')
        return error.NoInterval;

    var _intrvlbuf: [fmt.count("{d}", .{INTERVAL_MAX})]u8 = undefined;
    var intrvlfbs = io.fixedBufferStream(&_intrvlbuf);
    var intrvl = INTERVAL_DEFAULT;

    var format: ConfigFormat = undefined;

    var state: u8 = 0;
    for (line[pos..]) |ch| {
        if (state == 0) {
            switch (ch) {
                ' ', '\t' => {},
                '0'...'9' => {
                    _ = intrvlfbs.write(&[1]u8{ch}) catch unreachable;
                    state = 1;
                },
                else => return error.BadInterval,
            }
        } else if (state == 1) {
            switch (ch) {
                ' ', '\t' => {
                    intrvl = intervalFromBuf(intrvlfbs.getWritten());
                    state = 2;
                },
                '0'...'9' => {
                    _ = intrvlfbs.write(&[1]u8{ch}) catch {
                        return error.BadInterval;
                    };
                },
                else => return error.BadInterval,
            }
        } else if (state == 2) {
            switch (ch) {
                ' ', '\t' => {},
                '"' => {
                    format = try parseConfigFormat(
                        line[pos..],
                        wid,
                        &config_mem.formats_mem_buf[windx],
                        &format_errpos,
                    );
                    state = 3;
                    break;
                },
                else => {
                    return error.MissingQuotes;
                },
            }
        }
        pos += 1;
    }

    switch (state) {
        0 => return error.NoInterval,
        1, 2 => return error.NoFormat,
        3 => {
            config_mem.widgets_buf[windx].interval = intrvl;
            config_mem.formats_buf[windx] = format;
            return;
        },
        else => unreachable,
    }
}

fn parseColorLine(
    line: []const u8,
    wid_int_out: *u8,
    colors: *[typ.WIDGETS_MAX][COLORS_MAX]color.Color,
    errpos: *usize,
) !color.ColorUnion {
    // 'tis either FG or BG
    const start = "FG".len;
    if (line.len < start)
        unreachable;

    var fields = mem.tokenizeAny(u8, line[start..], " \t");

    // 0: widget, 1: hex OR opt, 2...: thresh:hex
    var nfields: u8 = 0;
    var ncolors: u8 = 0;
    var opt: ?u8 = null;

    errdefer errpos.* = start + fields.index - 1;
    while (fields.next()) |field| : (nfields += 1) {
        switch (nfields) {
            0 => {
                if (typ.strToWidEnum(field)) |ret| {
                    wid_int_out.* = @intFromEnum(ret);
                } else {
                    return error.UnknownWidget;
                }
            },
            1 => {
                const _wid = @as(typ.WidgetId, @enumFromInt(wid_int_out.*));
                if (typ.knobSupportsManyColors(_wid)) {
                    if (typ.knobValidManyColorsOptname(_wid, field)) {
                        for (typ.WID_TO_OPT_NAMES[wid_int_out.*], 0..) |name, j| {
                            if (mem.eql(u8, field, name)) {
                                opt = @intCast(j);
                                break;
                            }
                        } else {
                            return error.UnknownOption;
                        }
                        continue;
                    }
                    // fallthrough
                }
                var default: color.Color = .{ .thresh = 0, ._hex = undefined };
                if (!default.checkSetHex(field))
                    return error.BadColor;

                return .{ .default = default };
            },
            2...2 + COLORS_MAX - 1 => {
                var thresh: u8 = 0;
                if (mem.indexOfScalar(u8, field, ':')) |sep_i| {
                    thresh = fmt.parseUnsigned(u8, field[0..sep_i], 10) catch {
                        return error.BadThreshold;
                    };
                    if (thresh > 100)
                        return error.BadThreshold;

                    colors[wid_int_out.*][ncolors].thresh = thresh;

                    const colorstr = field[sep_i + 1 ..];
                    if (!colors[wid_int_out.*][ncolors].checkSetHex(colorstr))
                        return error.BadColor;

                    ncolors += 1;
                } else {
                    return error.NoDelimiter;
                }
            },
            else => return error.TooManyColors,
        }
    }

    if (nfields < 3)
        return error.IncompleteLine;

    return .{
        .color = .{
            .opt = opt.?,
            .colors = colors[wid_int_out.*][0..ncolors],
        },
    };
}
