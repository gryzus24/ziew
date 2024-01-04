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
pub const WidgetFormat = struct {
    nparts: usize = 0,
    parts: [typ.PARTS_MAX][]const u8 = undefined,
    opts: [typ.OPTS_MAX]Opt = undefined,

    pub fn iterParts(self: *const @This()) []const []const u8 {
        return self.parts[0..self.nparts];
    }

    pub fn iterOpts(self: *const @This()) []const Opt {
        return self.opts[0 .. self.nparts - 1];
    }
};

pub const Widget = struct {
    wid: typ.WidgetId,
    interval: typ.DeciSec = INTERVAL_DEFAULT,
    format: *const WidgetFormat,
    fg: color.ColorUnion = .{ .nocolor = {} },
    bg: color.ColorUnion = .{ .nocolor = {} },
};

pub const ConfigMem = struct {
    _nwidgets: usize = 0,
    _nformats: usize = 0,
    _ncolors: usize = 0,

    widgets: [typ.WIDGETS_MAX]Widget = undefined,
    formats: [typ.WIDGETS_MAX]WidgetFormat = undefined,
    colors: [COLORS_MAX]color.Color = undefined,

    pub fn newColor(self: *@This(), _color: color.Color) *color.Color {
        if (self._ncolors == self.colors.len)
            utl.fatal(&.{"config: color limit reached"});
        self.colors[self._ncolors] = _color;
        self._ncolors += 1;
        return &self.colors[self._ncolors - 1];
    }

    pub fn nLatestColorsSlice(self: *const @This(), n: usize) []const color.Color {
        @setRuntimeSafety(true);
        return self.colors[self._ncolors - n .. self._ncolors];
    }

    pub fn newWidget(self: *@This(), _widget: Widget) *Widget {
        if (self._nwidgets == self.widgets.len)
            utl.fatal(&.{"config: widget limit reached"});
        self.widgets[self._nwidgets] = _widget;
        self._nwidgets += 1;
        return &self.widgets[self._nwidgets - 1];
    }

    pub fn widgetsSlice(self: *const @This()) []const Widget {
        return self.widgets[0..self._nwidgets];
    }

    pub fn newWidgetFormat(self: *@This(), _format: WidgetFormat) *WidgetFormat {
        if (self._nformats == self.formats.len)
            utl.fatal(&.{"config: format limit reached"});
        self.formats[self._nformats] = _format;
        self._nformats += 1;
        return &self.formats[self._nformats - 1];
    }
};

fn defaultConfigPath(
    buf: *[typ.CONFIG_FILE_BUF_MAX]u8,
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
    buf: *[typ.CONFIG_FILE_BUF_MAX]u8,
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

    var nread = file.read(buf) catch |err| utl.fatal(
        &.{ "config: read: ", @errorName(err) },
    );
    if (nread >= buf.len) {
        const t = file.metadata() catch |err| utl.fatal(
            &.{ "config: file too big: ", @errorName(err) },
        );
        utl.fatalFmt("config: file too big by {} bytes", .{t.size() - nread});
    }
    // handle missing $'\n' edge case
    buf[nread] = '\n';

    return buf[0 .. nread + 1];
}

fn isColorLine(s: []const u8) bool {
    return (s.len >= 2 and (s[0] == 'F' or s[0] == 'B') and s[1] == 'G');
}

pub fn parse(config_mem: *ConfigMem, buf: []const u8) []const Widget {
    var lines = mem.tokenizeScalar(u8, buf, '\n');
    var errpos: usize = 0;
    var current_widget: ?*Widget = null;

    while (lines.next()) |line| {
        if (line[0] == '#') {
            {}
        } else if (isColorLine(line)) {
            var widget = current_widget orelse {
                utl.warn(&.{ "config: color without a widget: ", line });
                continue;
            };
            const cu = parseColorLine(
                config_mem,
                line,
                widget.wid,
                &errpos,
            ) catch |err| {
                utl.fatalPos(
                    &.{ "config: ", @errorName(err), ": ", line },
                    fmt.count("config: {s}: ", .{@errorName(err)}) + errpos,
                );
            };
            if (line[0] == 'F') {
                widget.fg = cu;
            } else {
                widget.bg = cu;
            }
        } else if (typ.strStartToWidEnum(line)) |wid| {
            current_widget = parseWidgetLine(
                config_mem,
                line,
                wid,
                &errpos,
            ) catch |err| {
                utl.fatalPos(
                    &.{ "config: ", @errorName(err), ": ", line },
                    fmt.count("config: {s}: ", .{@errorName(err)}) + errpos,
                );
            };
        } else {
            utl.warn(&.{ "config: unknown widget: ", line });
        }
    }

    const widgets = config_mem.widgetsSlice();
    var ncpu_widgets: usize = 0;
    for (widgets) |*w| if (w.wid == typ.WidgetId.CPU) {
        ncpu_widgets += 1;
    };
    if (ncpu_widgets > 1)
        utl.fatal(&.{"config: multiple CPU widgets not supported"});

    return widgets;
}

test "config parse" {
    const t = std.testing;

    var buf =
        \\CPU 0 "{%user}{%sys.5}"
        \\FG %all 0:fff 10:#999
        \\BG 282828
    ;
    var cm: ConfigMem = .{};

    const widgets = parse(&cm, buf);
    try t.expect(widgets.len == 1);

    const _cpu = widgets[0];
    try t.expect(_cpu.wid == .CPU);
    try t.expect(_cpu.interval == INTERVAL_MAX);
    try t.expect(_cpu.format.nparts == 3);
    try t.expect(mem.eql(u8, _cpu.format.parts[0], ""));
    try t.expect(mem.eql(u8, _cpu.format.parts[1], ""));
    try t.expect(mem.eql(u8, _cpu.format.parts[2], ""));
    try t.expect(_cpu.format.opts[0].opt == @intFromEnum(typ.CpuOpt.@"%user"));
    try t.expect(_cpu.format.opts[0].precision == OPT_PRECISION_DEFAULT);
    try t.expect(_cpu.format.opts[0].alignment == OPT_ALIGNMENT_DEFAULT);
    try t.expect(_cpu.format.opts[1].opt == @intFromEnum(typ.CpuOpt.@"%sys"));
    try t.expect(_cpu.format.opts[1].precision == 5);
    try t.expect(_cpu.format.opts[1].alignment == OPT_ALIGNMENT_DEFAULT);

    switch (_cpu.fg) {
        .nocolor, .default => return error.TestUnexpectedResult,
        .color => |*a| {
            try t.expect(a.opt == @intFromEnum(typ.CpuOpt.@"%all"));
            try t.expect(a.colors.len == 2);
            try t.expect(a.colors[0].thresh == 0);
            // TODO: change to t.expectEqual when it's usable
            try t.expect(mem.eql(u8, &a.colors[0]._hex, "#ffffff"));
            try t.expect(a.colors[1].thresh == 10);
            try t.expect(mem.eql(u8, &a.colors[1]._hex, "#999999"));
        },
    }
    switch (_cpu.bg) {
        .nocolor, .color => return error.TestUnexpectedResult,
        .default => |*w| {
            try t.expect(w.thresh == 0);
            try t.expect(mem.eql(u8, &w._hex, "#282828"));
        },
    }
}

pub fn defaultConfig(config_mem: *ConfigMem) []const Widget {
    const default_config =
        \\NET 20 "enp5s0{-}{ifname}: {inet} {flags}"
        \\FG state 0:a44 1:4a4
        \\DISK 200 "/{-}/ {available}"
        \\CPU 20 "CPU{%all.1>}"
        \\FG %all 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\MEM 20 "MEM {used} : {free} +{cached.0}"
        \\FG %used 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\BAT 300 "BAT0{-}BAT {%fulldesign.2} {state}"
        \\FG state 1:4a4 2:4a4
        \\BG %fulldesign 0:a00 15:220 25:
        \\TIME 20 "%A %d.%m ~ %H:%M:%S "
    ;
    return parse(config_mem, default_config);
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
    if (start == 0 or start == str.len) return error.NoInterval;

    var i: usize = start;
    defer pos.* += i;

    while (i < str.len) switch (str[i]) {
        '0'...'9' => i += 1,
        ' ', '\t' => break,
        else => return error.BadInterval,
    };
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

fn acceptWidgetFormat(
    config_mem: *ConfigMem,
    str: []const u8,
    wid: typ.WidgetId,
    pos: *usize,
) !*WidgetFormat {
    const start = skipWhitespace(str);
    pos.* += start;

    if (start == str.len) return error.NoFormat;
    if (str.len - start == 1) return error.MissingQuotes; // one character
    if (str[start] != '"') return error.MissingQuotes;

    var inside_brackets: bool = false;
    var optbuf: [typ.OPT_NAME_BUF_MAX]u8 = undefined;
    var optbuf_i: usize = 0;
    var part_i: usize = start + 1;

    var i: usize = start + 1;
    defer pos.* += i - start - 1;

    var format: WidgetFormat = .{};

    while (i < str.len and str[i] != '"') : (i += 1) {
        if (inside_brackets) switch (str[i]) {
            '}' => {
                format.opts[format.nparts - 1].opt = for (
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
                    format.opts[format.nparts - 1].precision = OPT_PRECISION_DEFAULT;
                    format.opts[format.nparts - 1].alignment = OPT_ALIGNMENT_DEFAULT;

                    // has any specifiers?
                    if (end + 1 < optbuf_i) {
                        for (optbuf[end + 1 .. optbuf_i]) |spec_ch| switch (spec_ch) {
                            '0'...'9' => {
                                format.opts[format.nparts - 1].precision = spec_ch - '0';
                            },
                            '<' => {
                                format.opts[format.nparts - 1].alignment = .left;
                            },
                            '>' => {
                                format.opts[format.nparts - 1].alignment = .right;
                            },
                            else => return error.UnknownSpecifier,
                        };
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
        } else switch (str[i]) {
            '{' => {
                inside_brackets = true;
                format.parts[format.nparts] = str[part_i..i];
                format.nparts += 1;
                if (format.nparts == typ.PARTS_MAX) return error.RogueUser;
            },
            '}' => return error.BracketMismatch,
            else => {},
        }
    }

    if (inside_brackets) return error.BracketMismatch;
    if (i == str.len) return error.MissingQuotes;

    format.parts[format.nparts] = str[part_i..i];
    format.nparts += 1;

    wid.panicOnInvalidArgs(&format);

    return config_mem.newWidgetFormat(format);
}

fn parseWidgetLine(
    config_mem: *ConfigMem,
    line: []const u8,
    wid: typ.WidgetId,
    errpos: *usize,
) !*Widget {
    var pos = @tagName(wid).len;
    errdefer errpos.* = pos;

    const interval = try acceptInterval(line[pos..], &pos);
    const format = try acceptWidgetFormat(config_mem, line[pos..], wid, &pos);

    return config_mem.newWidget(
        .{ .wid = wid, .interval = interval, .format = format },
    );
}

fn parseColorLine(
    config_mem: *ConfigMem,
    line: []const u8,
    wid: typ.WidgetId,
    errpos: *usize,
) !color.ColorUnion {
    // 'tis either FG or BG
    const pos = "FG".len;
    if (line.len < pos) unreachable;

    var fields = mem.tokenizeAny(u8, line[pos..], " \t");

    // 0: widget, 1: hex OR opt, 2...: thresh:hex
    var nfields: usize = 0;
    var nnew_colors: usize = 0;
    var opt: ?u8 = null;

    errdefer errpos.* = pos + fields.index - 1;
    while (fields.next()) |field| : (nfields += 1) switch (nfields) {
        0 => {
            const use_default = blk: {
                if (!wid.supportsManyColors()) break :blk true;
                if (!wid.isManyColorsOptnameSupported(field)) break :blk true;
                for (typ.WID_TO_OPT_NAMES[@intFromEnum(wid)], 0..) |name, j| {
                    if (mem.eql(u8, field, name)) {
                        opt = @intCast(j);
                        break :blk false;
                    }
                }
                return error.UnknownOption;
            };
            if (use_default) return .{
                .default = config_mem.newColor(try color.Color.init(0, field)).*,
            };
        },
        1...1 + COLORS_MAX - 1 => {
            if (mem.indexOfScalar(u8, field, ':')) |sep_i| {
                var thresh: u8 = fmt.parseUnsigned(u8, field[0..sep_i], 10) catch {
                    return error.BadThreshold;
                };
                if (thresh > 100) return error.BadThreshold;

                _ = config_mem.newColor(
                    try color.Color.init(thresh, field[sep_i + 1 ..]),
                );
                nnew_colors += 1;
            } else {
                return error.NoDelimiter;
            }
        },
        else => return error.TooManyColors,
    };
    if (nfields < 2) return error.IncompleteLine;

    return .{
        .color = .{
            .opt = opt.?,
            .colors = config_mem.nLatestColorsSlice(nnew_colors),
        },
    };
}
