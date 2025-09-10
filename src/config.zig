const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const w_bat = @import("w_bat.zig");
const w_cpu = @import("w_cpu.zig");
const w_dysk = @import("w_dysk.zig");
const w_mem = @import("w_mem.zig");
const w_net = @import("w_net.zig");
const w_read = @import("w_read.zig");
const w_time = @import("w_time.zig");
const ascii = std.ascii;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;

// == private =================================================================

const WidgetAllocator = struct {
    reg: *m.Region,
    widgets: []typ.Widget = &.{},
    format_parts: []typ.Format.Part = &.{},
    color_pairs: []color.Color.Active.Pair = &.{},

    pub fn newWidget(self: *@This(), wid: typ.Widget.Id) !*typ.Widget {
        const ret = try self.reg.backPushVec(&self.widgets);
        ret.* = .{ .wid = wid };
        return ret;
    }

    pub fn newFormatPart(self: *@This(), str: []const u8) !*typ.Format.Part {
        const ret = try self.reg.frontPushVec(&self.format_parts);
        ret.* = .{ .str = str };
        return ret;
    }

    pub fn newColorPair(self: *@This(), thresh: u8, hex: ?[6]u8) !void {
        const ret = try self.reg.frontPushVec(&self.color_pairs);
        ret.*.thresh = thresh;
        if (hex) |ok| {
            ret.*.data = .{ .hex = ok };
        } else {
            ret.*.data = .default;
        }
    }

    pub fn toOwnedWidgets(self: *@This()) []typ.Widget {
        const ret = self.widgets;
        self.widgets = &.{};
        return ret;
    }

    pub fn toOwnedFormatParts(self: *@This()) []typ.Format.Part {
        const ret = self.format_parts;
        self.format_parts = &.{};
        return ret;
    }

    pub fn toOwnedColorPairs(self: *@This()) []color.Color.Active.Pair {
        const ret = self.color_pairs;
        self.color_pairs = &.{};
        return ret;
    }
};

const Line = struct {
    nr: usize,
    fields: []Field = &.{},

    const Field = struct {
        str: []const u8,
    };
};

const ConfigAllocator = struct {
    reg: *m.Region,
    lines: []Line = &.{},
    fields: []Line.Field = &.{},

    pub fn newLine(self: *@This(), nr: usize) !*Line {
        const ret = try self.reg.backPushVec(&self.lines);
        ret.* = .{ .nr = nr };
        return ret;
    }

    pub fn newField(self: *@This(), str: []const u8) !*Line.Field {
        const ret = try self.reg.frontPushVec(&self.fields);
        ret.* = .{ .str = str };
        return ret;
    }

    pub fn toOwnedLines(self: *@This()) []Line {
        const ret = self.lines;
        self.lines = &.{};
        return ret;
    }

    pub fn toOwnedFields(self: *@This()) []Line.Field {
        const ret = self.fields;
        self.fields = &.{};
        return ret;
    }
};

const StitchedLine = struct {
    line: []const u8 = &.{},
    ebeg: usize,
    elen: usize,
};

const ParseError = error{
    BadArg,
    BadHex,
    BadInterval,
    BadThreshold,
    ExcessOfSpecifiers,
    MismatchedBrackets,
    MissingArg,
    MissingFields,
    MissingFormat,
    MissingIdentifier,
    MissingInterval,
    MissingOptionOrColor,
    MissingThreshold,
    MissingThresholdColorField,
    ThresholdTooBig,
    UnknownIdentifier,
    UnknownOption,
    UnknownOrUnsupportedOption,
    UnknownSpecifier,
    UnsupportedOption,
    WidgetSupportsOnlyDefaultColors,
} || error{NoSpaceLeft};

fn lineFieldSplit(reg: *m.Region, buf: []const u8) ![]Line {
    var ca: ConfigAllocator = .{ .reg = reg };
    var lineno: usize = 0;

    var lines = mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |_line| {
        lineno += 1;
        const line = mem.trim(u8, _line, " \t");

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var fields = try ca.newLine(lineno);
        var beg: usize = 0;
        var in_quote = false;
        var skip_ws = false;
        for (line, 0..) |ch, i| {
            switch (ch) {
                ' ', '\t' => {
                    if (in_quote) continue;
                    if (!skip_ws) {
                        skip_ws = true;
                        _ = try ca.newField(line[beg..i]);
                    }
                    beg = i + 1;
                },
                '"' => {
                    in_quote = !in_quote;
                    skip_ws = false;
                },
                else => {
                    skip_ws = false;
                },
            }
        }
        _ = try ca.newField(line[beg..]);
        fields.fields = ca.toOwnedFields();
    }
    return ca.toOwnedLines();
}

fn fieldWidget(field: Line.Field) ?typ.Widget.Id {
    return if (typ.strStartToTaggedWidgetId(field.str)) |wid|
        wid
    else
        null;
}

const ColorType = enum { fg, bg };
fn fieldColor(field: Line.Field) ?ColorType {
    if (mem.startsWith(u8, field.str, "FG")) {
        return .fg;
    } else if (mem.startsWith(u8, field.str, "BG")) {
        return .bg;
    } else {
        return null;
    }
}

const ColorOptResult = union(enum) {
    opt: u8,
    err: enum { unknown, unsupported },
};
fn fieldColorOpt(wid: typ.Widget.Id.ColorSupported, field: Line.Field) ColorOptResult {
    for (
        typ.WID_OPT_COLOR_SUPPORTED[@intFromEnum(wid)],
        typ.WID_OPT_NAMES[@intFromEnum(wid)],
        0..,
    ) |color_supported, name, j| {
        if (mem.eql(u8, field.str, name)) {
            return if (color_supported)
                .{ .opt = @intCast(j) }
            else
                .{ .err = .unsupported };
        }
    } else {
        return .{ .err = .unknown };
    }
}

fn acceptInterval(str: []const u8) !usize {
    var ret = fmt.parseUnsigned(typ.DeciSec, str, 10) catch |e| switch (e) {
        error.Overflow => return typ.WIDGET_INTERVAL_MAX,
        error.InvalidCharacter => return error.BadInterval,
    };
    if (ret == 0 or ret > typ.WIDGET_INTERVAL_MAX)
        ret = typ.WIDGET_INTERVAL_MAX;

    return ret;
}

fn acceptFormatString(
    wa: *WidgetAllocator,
    str: []const u8,
    wid: typ.Widget.Id.FormatRequired,
    err_note: *[]const u8,
    out: *typ.Format,
) !void {
    err_note.* = "";

    var current: *typ.Format.Part = undefined;

    var i: usize = 0;
    var inside_brackets = false;
    var str_beg = i;
    var opt_beg = i;

    while (i < str.len) : (i += 1) switch (str[i]) {
        '{' => {
            if (inside_brackets) return error.MismatchedBrackets;
            inside_brackets = true;

            current = try wa.newFormatPart(str[str_beg..i]);
            opt_beg = i + 1;
        },
        '}' => {
            if (!inside_brackets) return error.MismatchedBrackets;
            inside_brackets = false;

            const o_whole = str[opt_beg..i];
            const colon = mem.indexOfScalar(u8, o_whole, ':') orelse o_whole.len;

            const o_name_flag = o_whole[0..colon];
            const o_spec = o_whole[colon..];

            const atsign = mem.indexOfScalar(u8, o_name_flag, '@') orelse o_name_flag.len;
            const o_name = o_name_flag[0..atsign];
            const o_flag = o_name_flag[atsign..];

            if (o_flag.len != 0) {
                for (o_flag[1..]) |ch| switch (ch | 0x20) {
                    'd' => current.flags.diff = true,
                    'q' => current.flags.quiet = true,
                    else => {},
                };
            }

            current.opt = optblk: for (typ.WID_OPT_NAMES[@intFromEnum(wid)], 0..) |name, j| {
                if (!mem.eql(u8, name, o_name)) continue;

                if (o_spec.len != 0) {
                    var state: enum { alignment, width, precision } = .alignment;
                    for (o_spec[1..]) |ch| switch (state) {
                        .alignment => {
                            switch (ch) {
                                '<' => {
                                    current.wopts.alignment = .left;
                                    state = .width;
                                },
                                '>' => {
                                    current.wopts.alignment = .right;
                                    state = .width;
                                },
                                '.' => state = .precision,
                                else => return error.UnknownSpecifier,
                            }
                        },
                        .width => {
                            switch (ch) {
                                '0'...'9' => current.wopts.width = ch & 0x0f,
                                '.' => state = .precision,
                                else => return error.UnknownSpecifier,
                            }
                        },
                        .precision => {
                            switch (ch) {
                                '0'...'9' => {
                                    current.wopts.precision = @min(
                                        ch & 0x0f,
                                        unt.PRECISION_DIGITS_MAX,
                                    );
                                },
                                else => return error.ExcessOfSpecifiers,
                            }
                        },
                    };
                }
                break :optblk @intCast(j);
            } else {
                err_note.* = o_name;
                return error.UnknownOption;
            };
            str_beg = i + 1;
        },
        else => {},
    };
    if (inside_brackets) return error.MismatchedBrackets;

    out.*.part_opts = wa.toOwnedFormatParts();
    out.*.part_last = str[str_beg..];
}

fn accessField(fields: []Line.Field, i: usize) ?Line.Field {
    return if (i < fields.len) fields[i] else null;
}

fn unquoteField(field: Line.Field, prefix: []const u8) ![]const u8 {
    if (mem.startsWith(u8, field.str, prefix)) {
        const t = mem.trim(u8, field.str[prefix.len..], " \t");
        return mem.trim(u8, t, "\"");
    } else {
        return error.BadArg;
    }
}

fn stitchFields(reg: *m.Region, fields: []Line.Field, err_field: usize) !StitchedLine {
    const base = reg.frontSave(u8);
    var n: usize = 0;

    var ebeg: usize = 0;
    var elen: usize = 0;
    for (fields, 0..) |field, i| {
        if (i != 0)
            n += (try reg.frontWriteStr(" ")).len;
        if (i == err_field)
            ebeg = n;
        n += (try reg.frontWriteStr(field.str)).len;
        if (i == err_field)
            elen = n - ebeg;
    }
    return .{
        .line = reg.slice(u8, base, n),
        .ebeg = ebeg,
        .elen = elen,
    };
}

// Imagine this is a macro.
fn SET_FG_BG(widget_data: anytype, color_type: ColorType, fg_bg: anytype) void {
    switch (color_type) {
        .fg => widget_data.fg = fg_bg,
        .bg => widget_data.bg = fg_bg,
    }
}

// == public ==================================================================

pub const LineParseError = struct {
    nr: usize,
    line: []const u8,
    ebeg: usize,
    elen: usize,
    note: []const u8,
};

pub fn readFile(
    reg: *m.Region,
    path: [*:0]const u8,
) error{ FileNotFound, NoSpaceLeft }![]const u8 {
    const file = fs.cwd().openFileZ(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => utl.fatal(&.{ "config: open: ", @errorName(e) }),
    };
    defer file.close();

    const stat = file.stat() catch |e| utl.fatal(
        &.{ "config: could not get file size: ", @errorName(e) },
    );
    const buf = try reg.frontAllocMany(u8, stat.size);

    const nr_read = file.read(buf) catch |e| utl.fatal(
        &.{ "config: read: ", @errorName(e) },
    );
    if (nr_read != buf.len) utl.fatal(&.{"config: racy read"});

    return buf;
}

pub fn defaultConfig(reg: *m.Region) []const typ.Widget {
    const default_config =
        \\NET 20 arg=enp5s0 format="{arg} {inet}"
        \\FG state 0:a44 1:4a4
        \\NET 20 arg=enp5s0 format="RxTx {rx_bytes:>}/{tx_bytes:>} {rx_pkts@dq:>2}/{tx_pkts@dq:<2}"
        \\FG 686
        \\CPU 20 format="{blkbars} {all:>3} {sys:>3}"
        \\FG %all 0:999 48: 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\MEM 20 format="MEM {%used:>} {free:>} [{cached:>}]"
        \\FG %used 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\MEM 20 format="{dirty@q:>.0}:{writeback@q:>.0}"
        \\FG 999
        \\BAT 300 arg=BAT0 format="BAT {%fulldesign:.2} {state}"
        \\FG state 1:4a4 2:4a4
        \\BG %fulldesign 0:a00 15:220 25:
        \\TIME 20 arg="%A %d.%m ~ %H:%M:%S "
        \\FG bb9
    ;
    var err: LineParseError = undefined;
    return parse(reg, default_config, &err) catch unreachable;
}

pub fn parse(
    reg: *m.Region,
    buf: []const u8,
    err: *LineParseError,
) ParseError![]const typ.Widget {
    err.* = .{ .nr = 0, .line = &.{}, .ebeg = 0, .elen = 0, .note = "" };

    var wa: WidgetAllocator = .{ .reg = reg };
    var current: *typ.Widget = undefined;
    var current_field = ~@as(usize, 0);
    var err_note: []const u8 = &.{};

    const lines = try lineFieldSplit(reg, buf);
    for (lines) |line| {
        const fields = line.fields;

        errdefer err.* = blk: {
            const r = stitchFields(
                reg,
                fields,
                current_field,
            ) catch |e| switch (e) {
                error.NoSpaceLeft => StitchedLine{
                    .line = "config: parse: NoSpaceLeft",
                    .ebeg = 0,
                    .elen = 0,
                },
            };
            break :blk .{
                .nr = line.nr,
                .line = r.line,
                .ebeg = r.ebeg,
                .elen = r.elen,
                .note = err_note,
            };
        };

        current_field = 0;
        const f_wid_or_color = accessField(fields, current_field) orelse {
            return error.MissingIdentifier; // unreachable
        };

        if (fieldWidget(f_wid_or_color)) |wid| {
            current_field = 1;
            const f_interval = accessField(fields, current_field) orelse {
                return error.MissingInterval;
            };
            current = try wa.newWidget(wid);
            current.interval = try acceptInterval(f_interval.str);

            const arg_required = wid.requiresArgParam();
            const fmt_required = wid.requiresFormatParam();
            var arg_field: usize = 0;
            var fmt_field: usize = 0;

            current_field = 2;
            for (fields[current_field..], current_field..) |field, i| {
                if (mem.startsWith(u8, field.str, "arg=")) {
                    arg_field = i;
                } else if (mem.startsWith(u8, field.str, "format=")) {
                    fmt_field = i;
                }
            }
            current_field = ~@as(usize, 0);
            if (arg_required and arg_field == 0) return error.MissingArg;
            if (fmt_required and fmt_field == 0) return error.MissingFormat;
            current_field = arg_field;
            if (arg_required and arg_field > 0) {
                const arg = try unquoteField(fields[arg_field], "arg=");
                switch (wid.castTo(typ.Widget.Id.ArgRequired)) {
                    .TIME => current.wid.TIME = try .init(reg, arg),
                    .DISK => current.wid.DISK = try .init(reg, arg),
                    .NET => current.wid.NET = try .init(reg, arg),
                    .BAT => current.wid.BAT = try .init(reg, arg),
                    .READ => current.wid.READ = try .init(reg, arg),
                }
            }
            current_field = fmt_field;
            if (fmt_required and fmt_field > 0) {
                const fmt_wid = wid.castTo(typ.Widget.Id.FormatRequired);
                const ref = switch (fmt_wid) {
                    .MEM => blk: {
                        current.wid.MEM = try typ.Widget.Id.MemData.init(reg);
                        break :blk &current.wid.MEM.format;
                    },
                    .CPU => blk: {
                        current.wid.CPU = try typ.Widget.Id.CpuData.init(reg);
                        break :blk &current.wid.CPU.format;
                    },
                    .DISK => &current.wid.DISK.format,
                    .NET => &current.wid.NET.format,
                    .BAT => &current.wid.BAT.format,
                    .READ => &current.wid.READ.format,
                };
                try acceptFormatString(
                    &wa,
                    try unquoteField(fields[fmt_field], "format="),
                    fmt_wid,
                    &err_note,
                    ref,
                );
            }
        } else if (fieldColor(f_wid_or_color)) |color_type| {
            if (wa.widgets.len == 0) {
                utl.warn(&.{
                    "config: color without a widget: ",
                    (try stitchFields(reg, fields, 0)).line,
                });
                continue;
            }

            current_field = 1;
            const second_field = accessField(fields, current_field) orelse {
                return error.MissingOptionOrColor;
            };
            var co: color.Color = undefined;
            var opt: u8 = undefined;
            const wants_default_color = blk: {
                if (current.wid.supportsColor()) {
                    switch (fieldColorOpt(
                        current.wid.castTo(typ.Widget.Id.ColorSupported),
                        second_field,
                    )) {
                        .opt => |o| {
                            opt = o;
                            break :blk false;
                        },
                        .err => |e| switch (e) {
                            .unknown => if (fields.len > 2)
                                return error.UnknownOption
                            else
                                break :blk true, // might be a hex color
                            .unsupported => return error.UnsupportedOption,
                        },
                    }
                }
                break :blk true;
            };
            if (wants_default_color) {
                if (fields.len > 2) {
                    current_field = 2;
                    return error.WidgetSupportsOnlyDefaultColors;
                }
                if (color.acceptHex(second_field.str)) |ok| {
                    co = .{ .default = .{ .hex = ok } };
                } else {
                    return error.BadHex;
                }
            } else {
                current_field = ~@as(usize, 0);
                if (fields.len <= 2) return error.MissingThresholdColorField;
                current_field = 2;
                for (fields[current_field..]) |field| {
                    const sep = mem.indexOfScalar(u8, field.str, ':') orelse {
                        return error.MissingThreshold;
                    };
                    const thresh = fmt.parseUnsigned(u8, field.str[0..sep], 10) catch |e| switch (e) {
                        error.Overflow, error.InvalidCharacter => return error.BadThreshold,
                    };
                    if (thresh > 100) return error.ThresholdTooBig;

                    const hexstr = field.str[sep + 1 ..];
                    if (color.acceptHex(hexstr)) |ok| {
                        try wa.newColorPair(thresh, ok);
                    } else if (hexstr.len == 0 or mem.eql(u8, hexstr, "default")) {
                        try wa.newColorPair(thresh, null);
                    } else {
                        return error.BadHex;
                    }
                    current_field += 1;
                }
                co = .{
                    .active = .{
                        .opt = opt,
                        .pairs = wa.toOwnedColorPairs(),
                    },
                };
            }
            if (current.wid.supportsColor()) {
                switch (current.wid.castTo(typ.Widget.Id.ColorSupported)) {
                    .MEM => SET_FG_BG(current.wid.MEM, color_type, co),
                    .CPU => SET_FG_BG(current.wid.CPU, color_type, co),
                    .DISK => SET_FG_BG(current.wid.DISK, color_type, co),
                    .NET => SET_FG_BG(current.wid.NET, color_type, co),
                    .BAT => SET_FG_BG(current.wid.BAT, color_type, co),
                }
            } else {
                switch (current.wid.castTo(typ.Widget.Id.ColorOnlyDefault)) {
                    .TIME => SET_FG_BG(current.wid.TIME, color_type, co.default),
                    .READ => SET_FG_BG(current.wid.READ, color_type, co.default),
                }
            }
        } else {
            return error.UnknownIdentifier;
        }
    }
    return wa.toOwnedWidgets();
}

test parse {
    const t = std.testing;
    var buf: [2 * 4096]u8 align(64) = undefined;
    var reg: m.Region = .init(&buf);
    var err: LineParseError = undefined;

    var s: []const u8 = "A";
    try t.expectError(error.UnknownIdentifier, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 1);

    s = "CPU";
    try t.expectError(error.MissingInterval, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU a";
    try t.expectError(error.BadInterval, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 4);
    try t.expect(err.elen == 1);

    s = "CPU 1";
    try t.expectError(error.MissingFormat, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg";
    try t.expectError(error.MissingFormat, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg=";
    try t.expectError(error.MissingFormat, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg=\"";
    try t.expectError(error.MissingFormat, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg=\"\"";
    try t.expectError(error.MissingFormat, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg=\" \"";
    try t.expectError(error.MissingFormat, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg=\" \" format =";
    try t.expectError(error.MissingFormat, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg=\" \" format=\"{\"";
    try t.expectError(error.MismatchedBrackets, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 14);
    try t.expect(err.elen == 10);

    s = "CPU 1 arg=\" \" format=\"{}\"";
    try t.expectError(error.UnknownOption, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 14);
    try t.expect(err.elen == 11);

    s = "CPU 1 arg=\" \" format=\"{a}\"";
    try t.expectError(error.UnknownOption, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 14);
    try t.expect(err.elen == 12);

    s = "CPU 1 arg=\" \" format=\"{all:a}\"";
    try t.expectError(error.UnknownSpecifier, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 14);
    try t.expect(err.elen == 16);

    s = "CPU 1 arg=\" \" format=\"{all:.1}}\"";
    try t.expectError(error.MismatchedBrackets, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, s));
    try t.expect(err.nr == 1);
    try t.expect(err.ebeg == 14);
    try t.expect(err.elen == 18);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nF";
    try t.expectError(error.UnknownIdentifier, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "F"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 1);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nFG";
    try t.expectError(error.MissingOptionOrColor, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nFG 2a";
    try t.expectError(error.BadHex, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG 2a"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 3);
    try t.expect(err.elen == 2);

    s = "TIME 20 arg=\"%A %d.%m ~ %H:%M:%S\"\nFG 2a";
    try t.expectError(error.BadHex, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG 2a"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 3);
    try t.expect(err.elen == 2);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nFG %all";
    try t.expectError(error.MissingThresholdColorField, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG %all"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 0);
    try t.expect(err.elen == 0);

    s = "TIME 20 arg=\"%A %d.%m ~ %H:%M:%S\"\nFG %all";
    try t.expectError(error.BadHex, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG %all"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 3);
    try t.expect(err.elen == 4);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nFG %all a";
    try t.expectError(error.MissingThreshold, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG %all a"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 8);
    try t.expect(err.elen == 1);

    s = "TIME 20 arg=\"%A %d.%m ~ %H:%M:%S\"\nFG %all a";
    try t.expectError(error.WidgetSupportsOnlyDefaultColors, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG %all a"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 8);
    try t.expect(err.elen == 1);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nFG 777";
    const widgets = parse(&reg, s, &err) catch unreachable;
    try t.expect(widgets.len == 1);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nFG %all :";
    try t.expectError(error.BadThreshold, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG %all :"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 8);
    try t.expect(err.elen == 1);

    s = "CPU 1 arg=\" \" format=\"{all:.1}\"\nFG %all 2:333 3: 4:1 5:#222";
    try t.expectError(error.BadHex, parse(&reg, s, &err));
    try t.expect(mem.eql(u8, err.line, "FG %all 2:333 3: 4:1 5:#222"));
    try t.expect(err.nr == 2);
    try t.expect(err.ebeg == 17);
    try t.expect(err.elen == 3);
}
