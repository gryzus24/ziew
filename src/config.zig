const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
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

const Split = struct {
    beg: usize,
    end: usize,

    const zero: Split = .{ .beg = 0, .end = 0 };
};

const Splitter = struct {
    buf: []const u8,
    i: usize,
    want: enum { char, ws, quote },

    pub fn init(buf: []const u8) @This() {
        return .{ .buf = buf, .i = 0, .want = .char };
    }

    pub fn next(self: *@This()) ?Split {
        if (self.i == self.buf.len) return null;

        var beg: usize = 0;
        while (self.i < self.buf.len) : (self.i += 1) switch (self.buf[self.i]) {
            ' ', '\t' => {
                if (self.want == .ws) {
                    self.want = .char;
                    self.i += 1;
                    return .{ .beg = beg, .end = self.i - 1 };
                }
            },
            '"' => {
                if (self.want == .char) {
                    self.want = .quote;
                    beg = self.i + 1;
                } else if (self.want == .quote) {
                    self.want = .char;
                    self.i += 1;
                    return .{ .beg = beg, .end = self.i - 1 };
                }
            },
            else => {
                if (self.want == .char) {
                    self.want = .ws;
                    beg = self.i;
                }
            },
        };
        return .{ .beg = beg, .end = self.i };
    }
};

const FormatSplitter = struct {
    buf: []const u8,
    i: usize,

    pub const FormatSplit = union(enum) {
        ok: struct {
            part: Split,
            opt: Split,
        },
        err: struct {
            type: FailType,
            field: Split,
        },

        const FailType = enum { no_open, no_close };

        pub fn init(i: usize) @This() {
            return .{
                .ok = .{
                    .part = .{ .beg = i, .end = 0 },
                    .opt = .zero,
                },
            };
        }

        pub fn fail(t: FailType, field: Split) @This() {
            return .{ .err = .{ .type = t, .field = field } };
        }
    };

    pub fn init(buf: []const u8) @This() {
        return .{ .buf = buf, .i = 0 };
    }

    pub fn next(self: *@This()) ?FormatSplit {
        if (self.i == self.buf.len) return null;

        var r: FormatSplit = .init(self.i);
        var want: enum { opened, closed } = .opened;

        while (self.i < self.buf.len) : (self.i += 1) switch (self.buf[self.i]) {
            '{' => {
                switch (want) {
                    .opened => {
                        want = .closed;
                        r.ok.part.end = self.i;
                        r.ok.opt.beg = self.i + 1;
                    },
                    .closed => {
                        return .fail(.no_close, .{ .beg = r.ok.opt.beg, .end = self.i + 1 });
                    },
                }
            },
            '}' => {
                return switch (want) {
                    .opened => .fail(.no_open, .{ .beg = r.ok.part.beg, .end = self.i + 1 }),
                    .closed => blk: {
                        r.ok.opt.end = self.i;
                        self.i += 1;
                        break :blk r;
                    },
                };
            },
            else => {},
        };
        if (want == .opened) {
            r.ok.part.end = self.i;
            return r;
        }
        return .fail(.no_close, .{ .beg = r.ok.part.end, .end = self.i });
    }
};

const FormatResult = union(enum) {
    ok: typ.Format,
    err: struct {
        note: []const u8,
        field: Split,
    },

    pub fn fail(note: []const u8, field: Split) @This() {
        return .{ .err = .{ .note = note, .field = field } };
    }
};

fn acceptFormat(
    reg: *m.Region,
    str: []const u8,
    wid: typ.Widget.Id.AcceptsFormat,
) !FormatResult {
    var parts: []typ.Format.Part = &.{};
    const parts_off = reg.frontSave(typ.Format.Part);

    var fields: FormatSplitter = .init(str);
    while (fields.next()) |f| {
        const split = switch (f) {
            .ok => |ok| ok,
            .err => |e| switch (e.type) {
                .no_open => return .fail("no opening brace", e.field),
                .no_close => return .fail("no closing brace", e.field),
            },
        };

        // Is last_str?
        if (split.part.end == str.len) {
            break;
        }

        const field = str[split.opt.beg..split.opt.end];

        const Flags = packed struct {
            at: bool = false,
            colon: bool = false,
            dot: bool = false,
        };

        var want: Flags = .{ .at = true, .colon = true };

        var option: []const u8 = "";
        var flags: []const u8 = "";
        var specs: []const u8 = "";
        var prec: []const u8 = "";

        var cur: usize = 0;
        var i: usize = 0;
        while (i < field.len) : (i += 1) switch (field[i]) {
            '@' => {
                if (want.at) {
                    want.at = false;
                    option = field[cur..i];
                    cur = i + 1;
                }
            },
            ':' => {
                if (want.colon) {
                    if (want.at) {
                        option = field[cur..i];
                    } else {
                        flags = field[cur..i];
                    }
                    want = .{ .dot = true };
                    cur = i + 1;
                }
            },
            '.' => {
                if (want.dot) {
                    want.dot = false;
                    specs = field[cur..i];
                    cur = i + 1;
                }
            },
            else => {},
        };
        if (want.colon) {
            if (want.at) {
                option = field[cur..field.len];
            } else {
                flags = field[cur..field.len];
            }
        } else if (want.dot) {
            specs = field[cur..field.len];
        } else {
            prec = field[cur..field.len];
        }

        const opt: u8 = blk: for (typ.WID__OPT_NAMES[@intFromEnum(wid)], 0..) |name, j| {
            if (mem.eql(u8, option, name)) break :blk @intCast(j);
        } else {
            return .fail("unknown option", split.opt);
        };

        var ptr = try reg.frontPushVec(&parts);
        ptr.* = .initDefault(opt);

        for (flags) |ch| switch (ch | 0x20) {
            'd' => ptr.diff = true,
            'q' => ptr.quiet = true,
            else => {},
        };

        if (specs.len < 3) {
            for (specs) |ch| switch (ch) {
                '<' => ptr.wopts.alignment = .left,
                '>' => ptr.wopts.alignment = .right,
                '0'...'9' => ptr.wopts.width = ch & 0x0f,
                else => return .fail("unknown specifier", split.opt),
            };
        } else {
            return .fail("excessive specifiers", split.opt);
        }

        if (prec.len == 1) {
            ptr.wopts.precision = @min(prec[0] & 0x0f, unt.PRECISION_DIGITS_MAX);
        }
        if (prec.len > 1) {
            return .fail("excessive precision", split.opt);
        }
    }

    // Second pass - string copying and reference fixup.

    fields = .init(str);
    for (parts) |*part| {
        const s = switch (fields.next().?) {
            .ok => |ok| str[ok.part.beg..ok.part.end],
            .err => unreachable,
        };
        const off = reg.frontSave(u8);
        if (s.len > 0) _ = try reg.frontWriteStr(s);
        part.str = .{ .off = @intCast(off), .len = @intCast(s.len) };
    }

    var last_str: m.MemSlice(u8) = .zero;
    if (fields.next()) |f| {
        const s = switch (f) {
            .ok => |ok| str[ok.part.beg..ok.part.end],
            .err => unreachable,
        };
        const off = reg.frontSave(u8);
        if (s.len > 0) _ = try reg.frontWriteStr(s);
        last_str = .{ .off = @intCast(off), .len = @intCast(s.len) };
    }

    return .{
        .ok = .{
            .parts = .{ .off = @intCast(parts_off), .len = @intCast(parts.len) },
            .last_str = last_str,
        },
    };
}

fn acceptInterval(str: []const u8) ?typ.DeciSec {
    var ret = fmt.parseUnsigned(typ.DeciSec, str, 10) catch |e| switch (e) {
        error.Overflow => return typ.WIDGET_INTERVAL_MAX,
        error.InvalidCharacter => return null,
    };
    if (ret == 0 or ret > typ.WIDGET_INTERVAL_MAX)
        ret = typ.WIDGET_INTERVAL_MAX;

    return ret;
}

const ColorIdentifier = enum { fg, bg };

fn strColorIdentifier(str: []const u8) ?ColorIdentifier {
    if (mem.eql(u8, str, "FG")) {
        return .fg;
    } else if (mem.eql(u8, str, "BG")) {
        return .bg;
    } else {
        return null;
    }
}

const ColorOptResult = union(enum) {
    opt: u8,
    err: struct {
        str: []const u8,
        what: enum { unknown, unsupported },
    },
};

fn strColorOpt(wid: typ.Widget.Id.ActiveColorSupported, str: []const u8) ColorOptResult {
    for (
        typ.WID__OPTS_SUPPORTING_COLOR[@intFromEnum(wid)],
        typ.WID__OPT_NAMES[@intFromEnum(wid)],
        0..,
    ) |color_supported, name, j| {
        if (mem.eql(u8, str, name)) {
            return if (color_supported)
                .{ .opt = @intCast(j) }
            else
                .{ .err = .{ .str = str, .what = .unsupported } };
        }
    } else {
        return .{ .err = .{ .str = str, .what = .unknown } };
    }
}

const ParseWant = enum {
    identifier,
    interval,
    key,
    arg,
    format,
    color_default_or_active,
    color_default_done,
    color_active_pair,
};

const ParseLineResult = union(enum) {
    widget: struct {
        wid: typ.Widget.Id,
        interval: ?typ.DeciSec = null,
        arg: ?Split = null,
        format: ?Split = null,
    },
    color: struct {
        type: ColorIdentifier,
        data: ?union(enum) {
            hex: [6]u8,
            active: struct {
                opt: Split,
                pairs: []color.Active.Pair,
            },
        } = null,
    },
    err: struct {
        note: []const u8,
        field: Split,
    },

    pub fn fail(note: []const u8, field: Split) @This() {
        return .{ .err = .{ .note = note, .field = field } };
    }
};

fn parseLine(tmp: *m.Region, line: []const u8) !ParseLineResult {
    var result: ParseLineResult = undefined;

    var want: ParseWant = .identifier;
    var fields: Splitter = .init(line);
    while (fields.next()) |split| {
        const field = line[split.beg..split.end];

        switch (want) {
            .identifier => {
                if (typ.strWid(field)) |wid| {
                    result = .{ .widget = .{ .wid = wid } };
                    want = .interval;
                } else if (strColorIdentifier(field)) |ok| {
                    result = .{ .color = .{ .type = ok } };
                    want = .color_default_or_active;
                } else {
                    return .fail("unknown identifier", split);
                }
            },
            .interval => {
                if (acceptInterval(field)) |ok| {
                    result.widget.interval = ok;
                    want = .key;
                } else {
                    return .fail("bad interval", split);
                }
            },
            .key => {
                if (mem.eql(u8, field, "arg")) {
                    want = .arg;
                } else if (mem.eql(u8, field, "format")) {
                    want = .format;
                } else {
                    return .fail("bad key", split);
                }
            },
            .arg => {
                result.widget.arg = split;
                want = .key;
            },
            .format => {
                result.widget.format = split;
                want = .key;
            },
            .color_default_or_active => {
                if (color.acceptHex(field)) |ok| {
                    result.color.data = .{ .hex = ok };
                    want = .color_default_done;
                } else {
                    result.color.data = .{ .active = .{ .opt = split, .pairs = &.{} } };
                    want = .color_active_pair;
                }
            },
            .color_active_pair => {
                const sep = mem.indexOfScalar(u8, field, ':') orelse {
                    return .fail("missing threshold", split);
                };
                const thresh = fmt.parseUnsigned(u8, field[0..sep], 10) catch |e| switch (e) {
                    error.Overflow,
                    error.InvalidCharacter,
                    => return .fail("bad threshold", split),
                };
                if (thresh > 100) return .fail("threshold too big (0..100)", split);

                const hex = field[sep + 1 ..];
                if (color.acceptHex(hex)) |ok| {
                    const ptr = try tmp.frontPushVec(&result.color.data.?.active.pairs);
                    ptr.* = .{ .thresh = thresh, .data = .init(ok) };
                } else if (hex.len == 0 or mem.eql(u8, hex, "default")) {
                    const ptr = try tmp.frontPushVec(&result.color.data.?.active.pairs);
                    ptr.* = .{ .thresh = thresh, .data = .default };
                } else {
                    return .fail("bad hex", .{ .beg = split.beg + sep + 1, .end = split.end });
                }
            },
            .color_default_done => {
                log.warn(&.{ "config: ignoring garbage after default color: ", line });
                break;
            },
        }
    }
    return result;
}

// == public ==================================================================

pub fn defaultConfig(reg: *m.Region) []typ.Widget {
    const config =
        \\NET 20 arg enp5s0 format "{arg} {inet}"
        \\FG state 0:a44 1:4a4
        \\NET 20 arg enp5s0 format "RxTx {rx_bytes:>}/{tx_bytes:>} {rx_pkts@dq:>2}/{tx_pkts@dq:<2}"
        \\FG 686
        \\CPU 20 format "{blkbars} {all:>3} {sys:>3}"
        \\FG %all 0:999 48: 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\MEM 20 format "MEM {%used:>} {free:>} [{cached:>}]"
        \\FG %used 60:ff0 66:fc0 72:f90 78:f60 84:f30 90:f00
        \\MEM 20 format "{dirty@q:>.0}:{writeback@q:>.0}"
        \\FG 999
        \\BAT 300 arg BAT0 format "BAT {%fulldesign:.2} {state}"
        \\FG state 1:4a4 2:4a4
        \\BG %fulldesign 0:a00 15:220 25:
        \\TIME 20 arg "%A %d.%m ~ %H:%M:%S "
        \\FG bb9
    ;
    var reader: io.Reader = .fixed(config);
    var scratch: [128]u8 align(16) = undefined;
    const ret = parse(reg, &reader, &scratch) catch unreachable;
    return ret.ok;
}

pub const ParseResult = union(enum) {
    ok: []typ.Widget,
    err: Diagnostic,

    pub const Diagnostic = struct {
        note: []const u8,
        line: []const u8,
        line_nr: usize,
        field: Split,
    };

    pub fn fail(
        note: []const u8,
        line: []const u8,
        line_nr: usize,
        field: Split,
    ) @This() {
        return .{
            .err = .{
                .note = note,
                .line = line,
                .line_nr = line_nr,
                .field = field,
            },
        };
    }
};

pub fn parse(
    reg: *m.Region,
    reader: *io.Reader,
    scratch: []align(16) u8,
) error{NoSpaceLeft}!ParseResult {
    var widgets: []typ.Widget = &.{};
    var current: *typ.Widget = undefined;

    var line_nr: usize = 0;
    while (true) {
        const line_ = reader.takeDelimiterExclusive('\n') catch |e| switch (e) {
            error.ReadFailed => log.fatal(&.{"config: read failed"}),
            error.EndOfStream => break,
            error.StreamTooLong => log.fatal(&.{"config: line too long"}),
        };
        line_nr += 1;

        const line = mem.trim(u8, line_, " \t");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var tmp: m.Region = .init(scratch, "cfg_tmp");

        switch (try parseLine(&tmp, line)) {
            .widget => |wi| {
                current = try reg.backPushVec(&widgets);
                current.* = .initDefault(wi.wid);
                if (wi.interval) |ok| {
                    current.interval = ok;
                } else {
                    return .fail("widget requires interval", line, line_nr, .zero);
                }
                if (current.wid.acceptsArg()) {
                    if (wi.arg) |ok| {
                        const arg = line[ok.beg..ok.end];
                        switch (current.wid.castTo(typ.Widget.Id.AcceptsArg)) {
                            .TIME => current.wid.TIME = try .init(reg, arg),
                            .DISK => current.wid.DISK = try .init(reg, arg),
                            .NET => current.wid.NET = try .init(reg, arg),
                            .BAT => current.wid.BAT = try .init(reg, arg),
                            .READ => current.wid.READ = try .init(reg, arg),
                        }
                    } else {
                        return .fail("widget requires arg parameter", line, line_nr, .zero);
                    }
                }
                if (current.wid.acceptsFormat()) {
                    if (wi.format) |ok| {
                        const format = line[ok.beg..ok.end];
                        const wid = current.wid.castTo(typ.Widget.Id.AcceptsFormat);
                        const ref = switch (wid) {
                            .MEM => blk: {
                                current.wid.MEM = try .init(reg);
                                break :blk &current.wid.MEM.format;
                            },
                            .CPU => blk: {
                                current.wid.CPU = try .init(reg);
                                break :blk &current.wid.CPU.format;
                            },
                            .DISK => &current.wid.DISK.format,
                            .NET => &current.wid.NET.format,
                            .BAT => &current.wid.BAT.format,
                            .READ => &current.wid.READ.format,
                        };
                        ref.* = switch (try acceptFormat(reg, format, wid)) {
                            .ok => |f| f,
                            .err => |e| {
                                return .fail(e.note, line, line_nr, .{
                                    .beg = ok.beg + e.field.beg,
                                    .end = ok.beg + e.field.end,
                                });
                            },
                        };
                    } else {
                        return .fail("widget requires format parameter", line, line_nr, .zero);
                    }
                }
            },
            .color => |co| {
                if (widgets.len == 0) {
                    log.warn(&.{ "config: color without a widget: ", line });
                    continue;
                }
                const data = co.data orelse {
                    return .fail(
                        "widget's option and thresh:#hex pairs, or #hex required",
                        line,
                        line_nr,
                        .zero,
                    );
                };
                switch (data) {
                    .hex => |hex| switch (co.type) {
                        .fg => current.fg = .{ .static = .init(hex) },
                        .bg => current.bg = .{ .static = .init(hex) },
                    },
                    .active => |active| {
                        if (current.wid.supportsDefaultColorOnly())
                            return .fail(
                                "bad hex: widget doesn't support thresh:#hex pairs",
                                line,
                                line_nr,
                                active.opt,
                            );

                        const wid = current.wid.castTo(typ.Widget.Id.ActiveColorSupported);
                        const name = line[active.opt.beg..active.opt.end];
                        const opt = switch (strColorOpt(wid, name)) {
                            .opt => |o| o,
                            .err => |e| switch (e.what) {
                                .unknown => {
                                    return .fail(
                                        "unknown option",
                                        line,
                                        line_nr,
                                        active.opt,
                                    );
                                },
                                .unsupported => {
                                    return .fail(
                                        "option doesn't support thresh:#hex pairs",
                                        line,
                                        line_nr,
                                        active.opt,
                                    );
                                },
                            },
                        };
                        if (active.pairs.len == 0) {
                            return .fail(
                                "option requires thresh:#hex pairs",
                                line,
                                line_nr,
                                active.opt,
                            );
                        }
                        const T = color.Active.Pair;
                        const off = reg.frontSave(T);
                        const ptr = try reg.frontAllocMany(T, active.pairs.len);
                        @memcpy(ptr, active.pairs);

                        switch (co.type) {
                            .fg => {
                                current.fg = .{
                                    .active = .{
                                        .opt = opt,
                                        .pairs = .{
                                            .off = @intCast(off),
                                            .len = @intCast(active.pairs.len),
                                        },
                                    },
                                };
                            },
                            .bg => {
                                current.bg = .{
                                    .active = .{
                                        .opt = opt,
                                        .pairs = .{
                                            .off = @intCast(off),
                                            .len = @intCast(active.pairs.len),
                                        },
                                    },
                                };
                            },
                        }
                    },
                }
            },
            .err => |e| return .fail(e.note, line, line_nr, e.field),
        }
    }

    // Copy to front so we have a chance of fitting everything in one page.
    const b = reg.back;
    reg.back = reg.head.len;
    var widgets_front: []typ.Widget = &.{};
    for (widgets) |*w| {
        const ret = try reg.frontPushVec(&widgets_front);
        ret.* = w.*;
    }
    @memset(reg.head[b..], 0);
    return .{ .ok = widgets_front };
}

fn testParse(comptime s: []const u8, reg: *m.Region, scratch: []align(16) u8) !ParseResult {
    var ior: io.Reader = .fixed(s);
    return try parse(reg, &ior, scratch);
}

fn testDiag(r: ParseResult, note: []const u8, line_nr: usize, field: Split) !void {
    const t = std.testing;
    try t.expect(mem.eql(u8, r.err.note, note));
    try t.expect(r.err.line_nr == line_nr);
    try t.expect(r.err.field.beg == field.beg);
    try t.expect(r.err.field.end == field.end);
}

test parse {
    const t = std.testing;
    var buf: [0x2000]u8 align(64) = undefined;
    var reg: m.Region = .init(&buf, "cfgtest");
    var scratch: [256]u8 align(16) = undefined;

    var ior: io.Reader = .fixed("\n");
    var r = try parse(&reg, &ior, &scratch);
    try t.expect(r.ok.len == 0);

    r = try testParse("C\n", &reg, &scratch);
    try testDiag(r, "unknown identifier", 1, .{ .beg = 0, .end = 1 });

    r = try testParse("CPUGAH\n", &reg, &scratch);
    try testDiag(r, "unknown identifier", 1, .{ .beg = 0, .end = 6 });

    r = try testParse("\n#\t\n\n\nC\n", &reg, &scratch);
    try testDiag(r, "unknown identifier", 5, .{ .beg = 0, .end = 1 });

    r = try testParse("CPU\n", &reg, &scratch);
    try testDiag(r, "widget requires interval", 1, .zero);

    r = try testParse("CPU a\n", &reg, &scratch);
    try testDiag(r, "bad interval", 1, .{ .beg = 4, .end = 5 });

    r = try testParse("CPU 0.2\n", &reg, &scratch);
    try testDiag(r, "bad interval", 1, .{ .beg = 4, .end = 7 });

    r = try testParse("CPU 1\n", &reg, &scratch);
    try testDiag(r, "widget requires format parameter", 1, .zero);

    r = try testParse("CPU arg\n", &reg, &scratch);
    try testDiag(r, "bad interval", 1, .{ .beg = 4, .end = 7 });

    r = try testParse("CPU 1 arg\n", &reg, &scratch);
    try testDiag(r, "widget requires format parameter", 1, .zero);

    r = try testParse("CPU 1 format\n", &reg, &scratch);
    try testDiag(r, "widget requires format parameter", 1, .zero);

    r = try testParse("CPU 1 format \"\n", &reg, &scratch);
    try t.expect(r.ok.len == 1);

    r = try testParse("CPU 1 format \"\"\n", &reg, &scratch);
    try t.expect(r.ok.len == 1);

    r = try testParse("CPU 1 format \"{\"\n", &reg, &scratch);
    try testDiag(r, "no closing brace", 1, .{ .beg = 14, .end = 15 });

    r = try testParse("CPU 1 format \"{ \"\n", &reg, &scratch);
    try testDiag(r, "no closing brace", 1, .{ .beg = 14, .end = 16 });

    r = try testParse("CPU 1 format \"{ \n", &reg, &scratch);
    try testDiag(r, "no closing brace", 1, .{ .beg = 14, .end = 15 });

    r = try testParse("CPU 1 format \"}\"\n", &reg, &scratch);
    try testDiag(r, "no opening brace", 1, .{ .beg = 14, .end = 15 });

    r = try testParse("CPU 1 format \"%all}\"\n", &reg, &scratch);
    try testDiag(r, "no opening brace", 1, .{ .beg = 14, .end = 19 });

    r = try testParse("CPU 1 format %all}\n", &reg, &scratch);
    try testDiag(r, "no opening brace", 1, .{ .beg = 13, .end = 18 });

    r = try testParse("CPU 1 format {}\n", &reg, &scratch);
    try testDiag(r, "unknown option", 1, .{ .beg = 14, .end = 14 });

    r = try testParse("CPU 1 format { }\n", &reg, &scratch);
    try testDiag(r, "bad key", 1, .{ .beg = 15, .end = 16 });

    r = try testParse("CPU 1 format \"{ }\"\n", &reg, &scratch);
    try testDiag(r, "unknown option", 1, .{ .beg = 15, .end = 16 });

    r = try testParse("CPU 1 format \"{5all}\"\n", &reg, &scratch);
    try testDiag(r, "unknown option", 1, .{ .beg = 15, .end = 19 });

    // NOTE: underlining could be more precise.
    r = try testParse("CPU 1 format \"{%all:W}\"\n", &reg, &scratch);
    try testDiag(r, "unknown specifier", 1, .{ .beg = 15, .end = 21 });

    r = try testParse("CPU 1 format \"{%all:.11}\"\n", &reg, &scratch);
    try testDiag(r, "excessive precision", 1, .{ .beg = 15, .end = 23 });

    // NOTE: tabs break underlining.
    r = try testParse("CPU \t1   format {%all@q:.11}\n", &reg, &scratch);
    try testDiag(r, "excessive precision", 1, .{ .beg = 17, .end = 27 });

    r = try testParse("CPU 1 format {all:.1}\nF", &reg, &scratch);
    try testDiag(r, "unknown identifier", 2, .{ .beg = 0, .end = 1 });

    r = try testParse("CPU 1 format {all:.1}\nFGB", &reg, &scratch);
    try testDiag(r, "unknown identifier", 2, .{ .beg = 0, .end = 3 });

    r = try testParse("CPU 1 format {all:.1}\nFG", &reg, &scratch);
    try testDiag(r, "widget's option and thresh:#hex pairs, or #hex required", 2, .zero);

    r = try testParse("CPU 1 format {all:.1}\nFG 2a", &reg, &scratch);
    try testDiag(r, "unknown option", 2, .{ .beg = 3, .end = 5 });

    r = try testParse("TIME 1962 arg \"%A %d.%m ~ %H:%M:%S\"\nFG 2a", &reg, &scratch);
    try testDiag(r, "bad hex: widget doesn't support thresh:#hex pairs", 2, .{ .beg = 3, .end = 5 });

    r = try testParse("TIME 1962 arg \"%A %d.%m ~ %H:%M:%S\"\nFG 2ab", &reg, &scratch);
    try t.expect(r.ok.len == 1);

    r = try testParse("CPU 1 format {all:.1}\nFG all", &reg, &scratch);
    try testDiag(r, "option doesn't support thresh:#hex pairs", 2, .{ .beg = 3, .end = 6 });

    r = try testParse("CPU 1 format {all:.1}\nFG %all", &reg, &scratch);
    try testDiag(r, "option requires thresh:#hex pairs", 2, .{ .beg = 3, .end = 7 });

    r = try testParse("CPU 1 format {all:.1}\nFG %all w", &reg, &scratch);
    try testDiag(r, "missing threshold", 2, .{ .beg = 8, .end = 9 });

    r = try testParse("CPU 1 format {all:.1}\nFG %all w:", &reg, &scratch);
    try testDiag(r, "bad threshold", 2, .{ .beg = 8, .end = 10 });

    r = try testParse("CPU 1 format {all:.1}\nFG %all 1:", &reg, &scratch);
    try t.expect(r.ok.len == 1);

    r = try testParse("CPU 1 format {all:.1}\nFG %all 1:fh", &reg, &scratch);
    try testDiag(r, "bad hex", 2, .{ .beg = 10, .end = 12 });

    r = try testParse("CPU 1 format {all:.1}\nFG %all 1:ff8 98: 99:012 100:dd", &reg, &scratch);
    try testDiag(r, "bad hex", 2, .{ .beg = 29, .end = 31 });

    r = try testParse("CPU 1 format {all:.1}\nFG %all 1:ff8 98: 99:012 101:dd", &reg, &scratch);
    try testDiag(r, "threshold too big (0..100)", 2, .{ .beg = 25, .end = 31 });

    r = try testParse("CPU 1 format {all:.1}\nFG %all 1:ff8 98: 99:012 101:ddd", &reg, &scratch);
    try testDiag(r, "threshold too big (0..100)", 2, .{ .beg = 25, .end = 32 });
}
