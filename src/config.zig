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

// == private ==

const WidgetAllocator = struct {
    reg: *m.Region,
    widgets: []typ.Widget = &.{},
    format_parts: []typ.PartOpt = &.{},
    thresh_hexes: []typ.ThreshHex = &.{},

    pub fn newWidget(self: *@This(), wid: typ.WidgetId) !*typ.Widget {
        var new = try self.reg.backAllocMany(typ.Widget, 1);
        if (self.widgets.len > 0) {
            new.len = self.widgets.len + 1;
            mem.copyForwards(typ.Widget, new, self.widgets);
        }
        self.widgets = new;
        const ret = &self.widgets[self.widgets.len - 1];

        ret.* = .{ .wid = wid };
        return ret;
    }

    pub fn newPartOpt(self: *@This(), str: []const u8) !*typ.PartOpt {
        var new = try self.reg.frontAllocMany(typ.PartOpt, 1);
        if (self.format_parts.len == 0) {
            self.format_parts = new;
        } else {
            self.format_parts.len += 1;
        }
        new[0] = .{ .part = str };
        return &new[0];
    }

    pub fn newThreshHex(self: *@This(), thresh: u8, hex: []const u8) !*typ.ThreshHex {
        var new = try self.reg.frontAllocMany(typ.ThreshHex, 1);
        if (self.thresh_hexes.len == 0) {
            self.thresh_hexes = new;
        } else {
            self.thresh_hexes.len += 1;
        }
        new[0] = .{
            .thresh = thresh,
            .hex = blk: {
                var t: typ.Hex = .{};
                if (!t.set(hex)) return error.BadHex;
                break :blk t;
            },
        };
        return &new[0];
    }

    pub fn toOwnedWidgets(self: *@This()) []typ.Widget {
        const ret = self.widgets;
        self.widgets = &.{};
        return ret;
    }

    pub fn toOwnedFormatParts(self: *@This()) []typ.PartOpt {
        const ret = self.format_parts;
        self.format_parts = &.{};
        return ret;
    }

    pub fn toOwnedThreshHexes(self: *@This()) []typ.ThreshHex {
        const ret = self.thresh_hexes;
        self.thresh_hexes = &.{};
        return ret;
    }
};

const Identifier = union(enum) {
    widget: typ.WidgetId,
    color: enum { fg, bg },
};

const StringRange = struct {
    beg: usize,
    end: usize,
};

const WidgetParams = struct {
    arg: ?StringRange = null,
    format: ?StringRange = null,
};

const ParseError = error{
    @"arg=... Missing",
    @"format=... Missing",
    BadHex,
    BadInterval,
    BadThreshold,
    BracketMismatch,
    EmptyString,
    ExpectedOnlyOneArgParam,
    ExpectedOnlyOneFormatParam,
    ExpectedString,
    Huh,
    MissingEqualSign,
    MissingFields,
    NoBeginningQuote,
    NoInterval,
    NoMatchingQuote,
    NoThreshold,
    UnexpectedField,
    UnknownIdentifier,
    UnknownOption,
    UnknownParam,
    UnknownSpecifier,
    WidgetRequiresArgParam,
    WidgetRequiresFormatParam,
} || error{NoSpaceLeft};

fn acceptIdentifier(
    buf: []const u8,
    buf_pos: usize,
    err_pos: *usize,
    out: *Identifier,
) !usize {
    var i = buf_pos;
    errdefer err_pos.* = i;

    const beg = i;
    i = mem.indexOfAnyPos(u8, buf, i, " \t") orelse buf.len;

    const identifier = buf[beg..i];
    if (typ.strStartToTaggedWidgetId(identifier)) |wid| {
        out.* = .{ .widget = wid };
    } else if (mem.eql(u8, identifier, "FG")) {
        out.* = .{ .color = .fg };
    } else if (mem.eql(u8, identifier, "BG")) {
        out.* = .{ .color = .bg };
    } else {
        return error.UnknownIdentifier;
    }
    return i;
}

fn acceptInterval(
    buf: []const u8,
    buf_pos: usize,
    err_pos: *usize,
    out: *typ.DeciSec,
) !usize {
    var i = buf_pos;
    errdefer err_pos.* = i;

    const beg = i;
    while (i < buf.len) switch (buf[i]) {
        '0'...'9' => i += 1,
        ' ', '\t' => break,
        else => return error.BadInterval,
    };
    var ret = fmt.parseUnsigned(
        typ.DeciSec,
        buf[beg..i],
        10,
    ) catch |e| switch (e) {
        error.Overflow => return typ.WIDGET_INTERVAL_MAX,
        error.InvalidCharacter => unreachable,
    };
    if (ret == 0 or ret > typ.WIDGET_INTERVAL_MAX)
        ret = typ.WIDGET_INTERVAL_MAX;

    out.* = ret;
    return i;
}

fn acceptString(
    buf: []const u8,
    buf_pos: usize,
    err_pos: *usize,
    out: *StringRange,
    flag: enum { non_empty, allow_empty },
) !usize {
    var i = buf_pos;
    errdefer err_pos.* = i;

    if (buf_pos >= buf.len) return error.ExpectedString;
    if (buf[i] != '"') return error.NoBeginningQuote;
    i += 1; // skip '"'

    const beg = i;
    i = mem.indexOfScalarPos(u8, buf, i, '"') orelse return error.NoMatchingQuote;
    const end = i;
    i += 1; // skip '"'

    if (beg == end and flag == .non_empty) return error.EmptyString;

    out.* = .{ .beg = beg, .end = end };
    return i;
}

fn expectExact(buf: []const u8, pos: usize, str: []const u8) usize {
    return if (mem.startsWith(u8, buf[pos..], str)) pos + str.len else pos;
}

fn acceptWidgetParams(
    buf: []const u8,
    buf_pos: usize,
    err_pos: *usize,
    out: *WidgetParams,
) !usize {
    var i = buf_pos;
    errdefer err_pos.* = i;

    out.* = .{};

    var arg_seen = false;
    var format_seen = false;
    while (i < buf.len) {
        const param_type: enum { arg, format } = blk: {
            const prev = i;
            i = expectExact(buf, i, "arg");
            if (i != prev) {
                if (arg_seen) return error.ExpectedOnlyOneArgParam;
                arg_seen = true;
                break :blk .arg;
            }
            i = expectExact(buf, i, "format");
            if (i != prev) {
                if (format_seen) return error.ExpectedOnlyOneFormatParam;
                format_seen = true;
                break :blk .format;
            }
            return error.UnknownParam;
        };
        const prev = i;
        i = expectExact(buf, i, "=");
        if (prev == i) return error.MissingEqualSign;

        var strange: StringRange = undefined;
        i = try acceptString(
            buf,
            i,
            err_pos,
            &strange,
            if (param_type == .arg) .non_empty else .allow_empty,
        );
        switch (param_type) {
            .arg => out.*.arg = strange,
            .format => out.*.format = strange,
        }
        i = utl.skipSpacesTabs(buf, i) orelse break;
    }
    return i;
}

fn acceptWidgetFormatString(
    wa: *WidgetAllocator,
    buf: []const u8,
    buf_pos: usize,
    err_pos: *usize,
    wid: typ.WidgetId.FormatRequired,
    out: *typ.Format,
) !usize {
    var i = buf_pos;
    errdefer err_pos.* = i;

    var strange: StringRange = undefined;
    _ = try acceptString(buf, i, err_pos, &strange, .allow_empty);
    i = strange.beg;

    var inside_brackets = false;
    var str_beg = i;
    var opt_beg = i;
    var current: *typ.PartOpt = undefined;

    while (i < strange.end) : (i += 1) switch (buf[i]) {
        '{' => {
            if (inside_brackets) return error.BracketMismatch;
            inside_brackets = true;

            current = try wa.newPartOpt(buf[str_beg..i]);
            opt_beg = i + 1;
        },
        '}' => {
            if (!inside_brackets) return error.BracketMismatch;
            inside_brackets = false;

            current.opt = optblk: for (typ.WID_OPT_NAMES[@intFromEnum(wid)], 0..) |name, j| {
                const opt_str = buf[opt_beg..i];
                const dot = mem.indexOfScalar(u8, opt_str, '.');
                const opt_name = opt_str[0 .. dot orelse opt_str.len];

                if (!mem.eql(u8, name, opt_name)) continue;

                const specifiers = blk: {
                    if (dot == null) break :blk "";
                    if (dot == opt_str.len - 1) break :blk "";
                    break :blk opt_str[dot.? + 1 ..];
                };
                for (specifiers) |ch| switch (ch) {
                    '0'...'9' => current.precision = @min(ch & 0x0f, unt.PRECISION_DIGITS_MAX),
                    '<' => current.alignment = .left,
                    '>' => current.alignment = .right,
                    else => return error.UnknownSpecifier,
                };
                break :optblk @intCast(j);
            } else {
                return error.UnknownOption;
            };
            str_beg = i + 1;
        },
        else => {},
    };
    if (inside_brackets) return error.BracketMismatch;

    out.*.part_opts = wa.toOwnedFormatParts();
    out.*.part_last = buf[str_beg..strange.end];

    return strange.end + 1; // skip '"'
}

fn acceptColor(
    wa: *WidgetAllocator,
    buf: []const u8,
    buf_pos: usize,
    err_pos: *usize,
    wid: typ.WidgetId,
    out: *typ.Color,
) !usize {
    var i = buf_pos;
    errdefer err_pos.* = i;

    const beg = i;
    i = mem.indexOfAnyPos(u8, buf, i, " \t") orelse buf.len;
    const field = buf[beg..i];
    i = utl.skipSpacesTabs(buf, i) orelse buf.len;

    var opt: u8 = undefined;
    const expects_default_color = blk: {
        if (!wid.supportsColor()) break :blk true;
        for (
            typ.WID_OPT_COLOR_SUPPORTED[@intFromEnum(wid)],
            typ.WID_OPT_NAMES[@intFromEnum(wid)],
            0..,
        ) |color_supported, name, j| {
            if (color_supported and mem.eql(u8, field, name)) {
                opt = @intCast(j);
                break :blk false;
            }
        } else {
            if (i == buf.len) break :blk true;
            return error.UnknownOption;
        }
    };

    if (expects_default_color) {
        if (i != buf.len) return error.UnexpectedField;
        out.* = .{
            .default = blk: {
                var hex: typ.Hex = .{};
                if (!hex.set(field)) return error.BadHex;
                break :blk hex;
            },
        };
    } else {
        if (i == buf.len) return error.MissingFields;
        while (true) {
            const prev = i;
            const sep = mem.indexOfScalarPos(u8, buf, i, ':') orelse return error.NoThreshold;
            const thresh = fmt.parseUnsigned(u8, buf[prev..sep], 10) catch |e| switch (e) {
                error.Overflow, error.InvalidCharacter => return error.BadThreshold,
            };
            if (thresh > 100) return error.BadThreshold;

            i = mem.indexOfAnyPos(u8, buf, sep + 1, " \t") orelse buf.len;
            _ = try wa.newThreshHex(thresh, buf[sep + 1 .. i]);
            i = utl.skipSpacesTabs(buf, i) orelse break;
        }
        out.* = .{ .color = .{ .opt = opt, .colors = wa.toOwnedThreshHexes() } };
    }
    return i;
}

// == public ==================================================================

pub fn readFile(
    reg: *m.Region,
    path: [*:0]const u8,
) error{ FileNotFound, NoSpaceLeft }![]const u8 {
    const file = fs.cwd().openFileZ(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => utl.fatal(&.{ "config: open: ", @errorName(e) }),
    };
    defer file.close();

    const fmeta = file.metadata() catch |e| utl.fatal(
        &.{ "config: could not get file metadata: ", @errorName(e) },
    );
    const buf = try reg.frontAllocMany(u8, fmeta.size());

    const nread = file.read(buf) catch |e| utl.fatal(
        &.{ "config: read: ", @errorName(e) },
    );
    if (nread != buf.len) utl.fatal(&.{"config: racy read"});

    return buf;
}

pub fn defaultConfig(reg: *m.Region) []const typ.Widget {
    const default_config =
        \\NET 20 arg="enp5s0" format="{arg}: {inet} {flags}"
        \\FG state 0:a44 1:4a4
        \\DISK 200 arg="/" format="{arg} {available}"
        \\CPU 20 format="CPU{%all.1>}"
        \\FG %all 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\MEM 20 format="MEM {used} : {free} +{cached.0}"
        \\FG %used 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\BAT 300 arg="BAT0" format="BAT {%fulldesign.2} {state}"
        \\FG state 1:4a4 2:4a4
        \\BG %fulldesign 0:a00 15:220 25:
        \\TIME 20 arg="%A %d.%m ~ %H:%M:%S "
    ;
    var err_pos: usize = undefined;
    var err_line: []const u8 = undefined;
    return parse(reg, default_config, &err_pos, &err_line) catch unreachable;
}

pub fn parse(
    reg: *m.Region,
    _buf: []const u8, // underscored as I kept typing `buf` instead of `line`
    err_pos: *usize,
    err_line: *[]const u8,
) ParseError![]const typ.Widget {
    var wa: WidgetAllocator = .{ .reg = reg };
    var lines = mem.tokenizeScalar(u8, _buf, '\n');
    var current: *typ.Widget = undefined;

    while (lines.next()) |_line| {
        const line = mem.trim(u8, _line, " \t");

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        err_pos.* = 0;
        err_line.* = line;

        var i: usize = 0;
        var identifier: Identifier = undefined;
        i = try acceptIdentifier(line, i, err_pos, &identifier);
        switch (identifier) {
            .widget => |wid| {
                current = try wa.newWidget(wid);
                i = utl.skipSpacesTabs(line, i) orelse return error.NoInterval;
                i = try acceptInterval(line, i, err_pos, &current.interval);

                const arg_required = wid.requiresArgParam();
                const format_required = wid.requiresFormatParamameter();

                var params: WidgetParams = undefined;
                i = utl.skipSpacesTabs(line, i) orelse {
                    if (arg_required) return error.@"arg=... Missing";
                    if (format_required) return error.@"format=... Missing";
                    return error.Huh;
                };
                _ = try acceptWidgetParams(line, i, err_pos, &params);

                if (params.arg) |strange| {
                    if (arg_required) {
                        const arg = line[strange.beg..strange.end];
                        switch (wid.castTo(typ.WidgetId.ArgRequired)) {
                            .TIME => current.wid.TIME = try w_time.WidgetData.init(reg, arg),
                            .DISK => current.wid.DISK = try w_dysk.WidgetData.init(reg, arg),
                            .NET => current.wid.NET = try w_net.WidgetData.init(reg, arg),
                            .BAT => current.wid.BAT = try w_bat.WidgetData.init(reg, arg),
                            .READ => current.wid.READ = try w_read.WidgetData.init(reg, arg),
                        }
                    }
                } else if (arg_required) {
                    return error.WidgetRequiresArgParam;
                }

                if (params.format) |strange| {
                    if (format_required) {
                        const format_wid = wid.castTo(typ.WidgetId.FormatRequired);
                        const ref = switch (format_wid) {
                            .MEM => blk: {
                                current.wid.MEM = try reg.frontAlloc(w_mem.WidgetData);
                                current.wid.MEM.* = .{};
                                break :blk &current.wid.MEM.format;
                            },
                            .CPU => blk: {
                                current.wid.CPU = try reg.frontAlloc(w_cpu.WidgetData);
                                current.wid.CPU.* = .{};
                                break :blk &current.wid.CPU.format;
                            },
                            .DISK => &current.wid.DISK.format,
                            .NET => &current.wid.NET.format,
                            .BAT => &current.wid.BAT.format,
                            .READ => &current.wid.READ.format,
                        };
                        _ = try acceptWidgetFormatString(
                            &wa,
                            line,
                            strange.beg - 1,
                            err_pos,
                            format_wid,
                            ref,
                        );
                    }
                } else if (format_required) {
                    return error.WidgetRequiresFormatParam;
                }
            },
            .color => |color_type| {
                if (wa.widgets.len == 0) {
                    utl.warn(&.{ "config: color without a widget: ", line });
                    continue;
                }
                var co: typ.Color = undefined;
                i = utl.skipSpacesTabs(line, i) orelse return error.MissingFields;
                i = try acceptColor(&wa, line, i, err_pos, current.wid, &co);

                if (current.wid.supportsColor()) {
                    switch (current.wid.castTo(typ.WidgetId.ColorSupported)) {
                        .MEM => switch (color_type) {
                            .fg => current.wid.MEM.fg = co,
                            .bg => current.wid.MEM.bg = co,
                        },
                        .CPU => switch (color_type) {
                            .fg => current.wid.CPU.fg = co,
                            .bg => current.wid.CPU.bg = co,
                        },
                        .DISK => switch (color_type) {
                            .fg => current.wid.DISK.fg = co,
                            .bg => current.wid.DISK.bg = co,
                        },
                        .NET => switch (color_type) {
                            .fg => current.wid.NET.fg = co,
                            .bg => current.wid.NET.bg = co,
                        },
                        .BAT => switch (color_type) {
                            .fg => current.wid.BAT.fg = co,
                            .bg => current.wid.BAT.bg = co,
                        },
                    }
                } else {
                    switch (current.wid.castTo(typ.WidgetId.ColorOnlyDefault)) {
                        .TIME => switch (color_type) {
                            .fg => current.wid.TIME.fg = co.default,
                            .bg => current.wid.TIME.bg = co.default,
                        },
                        .READ => switch (color_type) {
                            .fg => current.wid.READ.fg = co.default,
                            .bg => current.wid.READ.bg = co.default,
                        },
                    }
                }
            },
        }
    }
    err_pos.* = 0;
    err_line.* = &.{};
    return wa.toOwnedWidgets();
}

test parse {
    const t = std.testing;
    var buf: [4096]u8 align(16) = undefined;
    var reg = m.Region.init(&buf);
    var err_pos: usize = undefined;
    var err_line: []const u8 = undefined;

    var s: []const u8 = "A";
    try t.expectError(error.UnknownIdentifier, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 1);
    s = "CPU";
    try t.expectError(error.NoInterval, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 0);
    s = "CPU a";
    try t.expectError(error.BadInterval, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 4);
    s = "CPU 1";
    try t.expectError(error.@"format=... Missing", parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 0);
    s = "CPU 1 arg";
    try t.expectError(error.MissingEqualSign, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 9);
    s = "CPU 1 arg=";
    try t.expectError(error.ExpectedString, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 10);
    s = "CPU 1 arg=\"";
    try t.expectError(error.NoMatchingQuote, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 10);
    s = "CPU 1 arg=\"\"";
    try t.expectError(error.EmptyString, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 10);
    s = "CPU 1 arg=\" \"";
    try t.expectError(error.WidgetRequiresFormatParam, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 0);
    s = "CPU 1 arg=\" \" format =";
    try t.expectError(error.MissingEqualSign, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 20);
    s = "CPU 1 arg=\" \" format=\"{\"";
    try t.expectError(error.BracketMismatch, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 23);
    s = "CPU 1 arg=\" \" format=\"{}\"";
    try t.expectError(error.UnknownOption, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 23);
    s = "CPU 1 arg=\" \" format=\"{}\"";
    try t.expectError(error.UnknownOption, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 23);
    s = "CPU 1 arg=\" \" format=\"{a}\"";
    try t.expectError(error.UnknownOption, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 24);
    s = "CPU 1 arg=\" \" format=\"{a}\"";
    try t.expectError(error.UnknownOption, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 24);
    s = "CPU 1 arg=\" \" format=\"{all.a}\"";
    try t.expectError(error.UnknownSpecifier, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 28);
    s = "CPU 1 arg=\" \" format=\"{all.1}}\"";
    try t.expectError(error.BracketMismatch, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 29);
    s = "CPU 1 arg=\" \" format=\"{all.1}\"\nF";
    try t.expectError(error.UnknownIdentifier, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 1);
    s = "CPU 1 arg=\" \" format=\"{all.1}\"\nFG";
    try t.expectError(error.MissingFields, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 0);
    s = "CPU 1 arg=\" \" format=\"{all.1}\"\nFG %";
    try t.expectError(error.BadHex, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 4);
    s = "CPU 1 arg=\" \" format=\"{all.1}\"\nFG %all";
    try t.expectError(error.MissingFields, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 7);
    s = "CPU 1 arg=\" \" format=\"{all.1}\"\nFG %all a";
    try t.expectError(error.NoThreshold, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 8);
    s = "CPU 1 arg=\" \" format=\"{all.1}\"\nFG %all :";
    try t.expectError(error.BadThreshold, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 8);
    s = "CPU 1 arg=\" \" format=\"{all.1}\"\nFG %all 2:333 3: 4:1";
    try t.expectError(error.BadHex, parse(&reg, s, &err_pos, &err_line));
    try t.expect(err_pos == 20);
}
