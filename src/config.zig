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
    widgets_buf: [typ.WIDGETS_MAX]Widget = undefined,
    formats_buf: [typ.WIDGETS_MAX]ConfigFormat = undefined,
    formats_mem_buf: [typ.WIDGETS_MAX]ConfigFormatMem = undefined,
    colors_buf: [COLORS_MAX]color.Color = undefined,

    ncolors: usize = 0,

    pub fn newColor(self: *@This(), _color: color.Color) void {
        if (self.ncolors == COLORS_MAX)
            utl.fatalFmt("config: color limit ({d}) reached", .{COLORS_MAX});

        self.colors_buf[self.ncolors] = _color;
        self.ncolors += 1;
    }

    pub fn nLatestColorsSlice(self: *const @This(), n: usize) []const color.Color {
        @setRuntimeSafety(true);
        return self.colors_buf[self.ncolors - n .. self.ncolors];
    }
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
        utl.warn(&.{"config: $HOME and $XDG_CONFIG_HOME not set"});
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
        error.PathTooLong => utl.fatal(&.{ "config: ", @errorName(err) }),
    });

    const file = fs.cwd().openFileZ(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => utl.fatal(&.{ "config: open: ", @errorName(err) }),
    };
    defer file.close();

    const nread = nread_blk: {
        var nread = file.read(buf) catch |err|
            utl.fatal(&.{ "config: read: ", @errorName(err) });
        if (nread < buf.len) {
            // handle missing $'\n' edge case
            buf[nread] = '\n';
            break :nread_blk nread + 1;
        } else {
            const sz = sz_blk: {
                const meta = file.metadata() catch |err|
                    utl.fatal(&.{ "config: file too big: ", @errorName(err) });
                break :sz_blk meta.size();
            };
            utl.fatalFmt("config: file too big by {} bytes", .{sz - nread});
        }
    };
    return buf[0..nread];
}

pub fn parse(buf: []const u8, config_mem: *ConfigMem) Config {
    var nwidgets: usize = 0;
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
            var wid_int: u8 = undefined;
            const config_color = parseColorLine(
                line,
                &wid_int,
                config_mem,
                &errpos,
            ) catch |err| {
                utl.fatalPos(
                    &.{ "config: ", @errorName(err), ": ", line },
                    fmt.count("config: {s}: ", .{@errorName(err)}) + errpos,
                );
            };
            for (config_mem.widgets_buf[0..nwidgets]) |*widget| {
                if (@intFromEnum(widget.wid) == wid_int) {
                    if (line[0] == 'F') {
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
                        &.{ "config: ", @errorName(err), ": ", line },
                        fmt.count("config: {s}: ", .{@errorName(err)}) + errpos,
                    );
                };
                seen[wid_int] = true;
                config_mem.widgets_buf[nwidgets].wid = wid;
                wid.panicOnInvalidArgs(&config_mem.formats_buf[nwidgets]);
                nwidgets += 1;
            }
        } else {
            utl.warn(&.{ "config: unknown widget: '", line, "'" });
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
    var cm: ConfigMem = .{};

    var conf = parse(buf, &cm);
    try t.expect(conf.widgets.len == 1);
    try t.expect(conf.widgets[0].wid == .CPU);
    try t.expect(conf.widgets[0].interval == INTERVAL_MAX);
    switch (conf.widgets[0].fgcu) {
        .nocolor, .default => return error.TestUnexpectedResult,
        .color => |*w| {
            try t.expect(w.opt == @intFromEnum(typ.CpuOpt.@"%all"));
            try t.expect(w.colors.len == 2);
            try t.expect(w.colors[0].thresh == 0);
            // TODO: change to t.expectEqual when it's usable
            try t.expect(mem.eql(u8, &w.colors[0]._hex, "#ffffff"));
            try t.expect(w.colors[1].thresh == 10);
            try t.expect(mem.eql(u8, &w.colors[1]._hex, "#999999"));
        },
    }
    switch (conf.widgets[0].bgcu) {
        .nocolor, .color => return error.TestUnexpectedResult,
        .default => |*w| {
            try t.expect(w.thresh == 0);
            try t.expect(mem.eql(u8, &w._hex, "#282828"));
        },
    }

    try t.expect(conf.formats.len == 1);
    try t.expect(conf.formats[0].nparts == 3);
    try t.expect(mem.eql(u8, conf.formats[0].parts[0], ""));
    try t.expect(mem.eql(u8, conf.formats[0].parts[1], ""));
    try t.expect(mem.eql(u8, conf.formats[0].parts[2], ""));

    try t.expect(conf.formats[0].opts[0].opt == @intFromEnum(typ.CpuOpt.@"%user"));
    try t.expect(conf.formats[0].opts[1].opt == @intFromEnum(typ.CpuOpt.@"%sys"));

    try t.expect(conf.formats[0].opts[0].precision == OPT_PRECISION_DEFAULT);
    try t.expect(conf.formats[0].opts[1].precision == OPT_PRECISION_DEFAULT);

    try t.expect(conf.formats[0].opts[0].alignment == OPT_ALIGNMENT_DEFAULT);
    try t.expect(conf.formats[0].opts[1].alignment == OPT_ALIGNMENT_DEFAULT);
}

pub fn defaultConfig(config_mem: *ConfigMem) Config {
    const default_config =
        \\ETH  20  "enp5s0{-}{ifname}: {inet} {flags}"
        \\DISK 200 "/{-}/ {available}"
        \\CPU  20  "CPU{%all.1>}"
        \\MEM  20  "MEM {used} : {free} +{cached.0}"
        \\BAT  300 "BAT0{-}BAT {%fulldesign.2} {state}"
        \\TIME 20  "%A %d.%m ~ %H:%M:%S "
        \\FG ETH state 0:a44 1:4a4
        \\FG CPU %all  60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\FG MEM %used 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\FG BAT state 1:4a4 2:4a4
        \\BG BAT %fulldesign 0:a00 15:220 25:
    ;
    return parse(default_config, config_mem);
}

// == private ==

const INTERVAL_DEFAULT: typ.DeciSec = 50;
const INTERVAL_MAX = 1 << 31;

const OPT_PRECISION_DEFAULT = 1;
const OPT_ALIGNMENT_DEFAULT = .none;

const COLORS_MAX = 100;

fn skipWhitespace(str: []const u8) usize {
    var i: usize = 0;
    while (i < str.len and (str[i] == ' ' or str[i] == '\t')) : (i += 1) {}
    return i;
}

fn acceptInterval(str: []const u8, pos: *usize) !typ.DeciSec {
    const start = skipWhitespace(str);
    if (start == str.len) return error.NoInterval;

    var i: usize = start;
    defer pos.* += i;

    out: while (i < str.len) {
        switch (str[i]) {
            '0'...'9' => i += 1,
            ' ', '\t' => break :out,
            else => return error.BadInterval,
        }
    }
    const ret = fmt.parseUnsigned(
        typ.DeciSec,
        str[start..i],
        10,
    ) catch |err| switch (err) {
        error.Overflow => return INTERVAL_MAX,
        error.InvalidCharacter => unreachable,
    };
    if (ret == 0 or ret > INTERVAL_MAX) return INTERVAL_MAX;
    return ret;
}

fn acceptConfigFormat(
    str: []const u8,
    wid: typ.WidgetId,
    format_mem: *ConfigFormatMem,
    pos: *usize,
) !ConfigFormat {
    const start = skipWhitespace(str);
    pos.* += start;

    if (start == str.len) return error.NoFormat;
    if (str.len - start == 1) return error.MissingQuotes; // one character
    if (str[start] != '"') return error.MissingQuotes;

    var inside_brackets: bool = false;
    var nparts: u8 = 0;
    var optbuf: [typ.OPT_NAME_BUF_MAX]u8 = undefined;
    var optbuf_i: usize = 0;
    var part_i: usize = start + 1;

    var i: usize = start + 1;
    defer pos.* += i - start - 1;

    while (i < str.len and str[i] != '"') : (i += 1) {
        if (inside_brackets) {
            switch (str[i]) {
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

                        if (!mem.eql(u8, name, optbuf[0..end])) continue;

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
                    part_i = i + 1;
                    inside_brackets = false;
                },
                '{' => return error.BracketMismatch,
                else => {
                    if (optbuf_i == typ.OPT_NAME_BUF_MAX)
                        return error.UnknownOption;

                    optbuf[optbuf_i] = str[i];
                    optbuf_i += 1;
                },
            }
        } else {
            switch (str[i]) {
                '{' => {
                    inside_brackets = true;
                    format_mem.parts[nparts] = str[part_i..i];
                    nparts += 1;
                    if (nparts == typ.PARTS_MAX) return error.RogueUser;
                },
                '}' => return error.BracketMismatch,
                else => {},
            }
        }
    }

    if (inside_brackets) return error.BracketMismatch;
    if (i == str.len) return error.MissingQuotes;

    format_mem.parts[nparts] = str[part_i..i];
    nparts += 1;

    return .{
        .nparts = nparts,
        .parts = &format_mem.parts,
        .opts = &format_mem.opts,
    };
}

fn parseWidgetLine(
    line: []const u8,
    wid: typ.WidgetId,
    windx: usize,
    config_mem: *ConfigMem,
    errpos: *usize,
) !void {
    var pos = @tagName(wid).len;
    errdefer errpos.* = pos;

    config_mem.widgets_buf[windx].interval = try acceptInterval(line[pos..], &pos);
    config_mem.formats_buf[windx] = try acceptConfigFormat(
        line[pos..],
        wid,
        &config_mem.formats_mem_buf[windx],
        &pos,
    );
}

fn parseColorLine(
    line: []const u8,
    wid_int_out: *u8,
    config_mem: *ConfigMem,
    errpos: *usize,
) !color.ColorUnion {
    // 'tis either FG or BG
    const pos = "FG".len;
    if (line.len < pos) unreachable;

    var fields = mem.tokenizeAny(u8, line[pos..], " \t");

    // 0: widget, 1: hex OR opt, 2...: thresh:hex
    var nfields: u8 = 0;
    var nnew_colors: u8 = 0;
    var opt: ?u8 = null;

    errdefer errpos.* = pos + fields.index - 1;
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
                if (_wid.supportsManyColors()) {
                    if (_wid.isManyColorsOptnameSupported(field)) {
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
                const default = try color.Color.init(0, field);
                config_mem.newColor(default);

                return .{ .default = default };
            },
            2...2 + COLORS_MAX - 1 => {
                if (mem.indexOfScalar(u8, field, ':')) |sep_i| {
                    var thresh: u8 = fmt.parseUnsigned(u8, field[0..sep_i], 10) catch {
                        return error.BadThreshold;
                    };
                    if (thresh > 100) return error.BadThreshold;

                    config_mem.newColor(
                        try color.Color.init(thresh, field[sep_i + 1 ..]),
                    );
                    nnew_colors += 1;
                } else {
                    return error.NoDelimiter;
                }
            },
            else => return error.TooManyColors,
        }
    }
    if (nfields < 3) return error.IncompleteLine;

    return .{
        .color = .{
            .opt = opt.?,
            .colors = config_mem.nLatestColorsSlice(nnew_colors),
        },
    };
}
