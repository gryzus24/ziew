const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

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

const enums = std.enums;
const fmt = std.fmt;
const mem = std.mem;

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

    fn init(buf: []const u8) @This() {
        return .{ .buf = buf, .i = 0, .want = .char };
    }

    fn next(self: *@This()) ?Split {
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

        fn init(i: usize) @This() {
            return .{
                .ok = .{
                    .part = .{ .beg = i, .end = 0 },
                    .opt = .zero,
                },
            };
        }

        fn fail(t: FailType, field: Split) @This() {
            return .{ .err = .{ .type = t, .field = field } };
        }
    };

    fn init(buf: []const u8) @This() {
        return .{ .buf = buf, .i = 0 };
    }

    fn next(self: *@This()) ?FormatSplit {
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

    fn fail(note: []const u8, field: Split) @This() {
        return .{ .err = .{ .note = note, .field = field } };
    }
};

fn acceptFormat(reg: *umem.Region, str: []const u8, wid: typ.Widget.Id) !FormatResult {
    var parts: []typ.Format.Part = &.{};
    const parts_sp = reg.save(typ.Format.Part, .front);

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
        if (split.part.end == str.len)
            break;

        var i: usize = 0;
        const field = str[split.opt.beg..split.opt.end];

        var pct_prefix = false;
        if (field.len > 0 and field[0] == '%') {
            pct_prefix = true;
            i = 1;
        }

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

        var cur = i;
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

        const opt: u8 = blk: for (typ.WID__OPTION_NAMES[@intFromEnum(wid)], 0..) |name, j| {
            if (mem.eql(u8, option, name)) break :blk @intCast(j);
        } else {
            return .fail("unknown option", split.opt);
        };

        var ptr = try reg.pushVec(&parts, .front);
        ptr.* = .initDefault(.zero, opt);

        ptr.flags.pct = pct_prefix;
        for (flags) |ch| switch (ch | 0x20) {
            'd' => ptr.flags.diff = true,
            's' => {
                ptr.flags.diff = true;
                ptr.flags.persec = true;
            },
            'q' => ptr.flags.quiet = true,
            else => {},
        };

        if (specs.len < 3) {
            for (specs) |ch| switch (ch) {
                '<' => ptr.wopts.alignment = .left,
                '>' => ptr.wopts.alignment = .right,
                '0'...'9' => ptr.wopts.setWidth(ch & 0x0f),
                else => return .fail("unknown specifier", split.opt),
            };
        } else {
            return .fail("excessive specifiers", split.opt);
        }

        if (prec.len == 1) {
            ptr.wopts.setPrecision(prec[0] & 0x0f);
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
        const sp = reg.save(u8, .front);
        if (s.len > 0) _ = try reg.writeStr(s, .front);
        part.str = .{ .off = @intCast(sp.off), .len = @intCast(s.len) };
    }

    var last_str: umem.MemSlice(u8) = .zero;
    if (fields.next()) |f| {
        const s = switch (f) {
            .ok => |ok| str[ok.part.beg..ok.part.end],
            .err => unreachable,
        };
        const sp = reg.save(u8, .front);
        if (s.len > 0) _ = try reg.writeStr(s, .front);
        last_str = .{ .off = @intCast(sp.off), .len = @intCast(s.len) };
    }

    return .{
        .ok = .{
            .parts = .{ .off = @intCast(parts_sp.off), .len = @intCast(parts.len) },
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

fn acceptPrefix(str: []const u8, prefix: u8) bool {
    return (str.len > 0 and str[0] == prefix);
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
    ok: struct {
        opt: u8,
        pct: bool,
    },
    err: struct {
        str: []const u8,
        what: enum { unknown, unsupported },
    },
};

fn strColorOpt(wid: typ.Widget.Id.ActiveColorSupported, str: []const u8) ColorOptResult {
    var pct = false;
    if (wid == .MEM or wid == .CPU)
        pct = acceptPrefix(str, '%');

    const i: u8 = @intFromBool(pct);
    for (
        typ.WID__OPTIONS_SUPPORTING_COLOR[@intFromEnum(wid)],
        typ.WID__OPTION_NAMES[@intFromEnum(wid)],
        0..,
    ) |support, name, opt| {
        if (mem.eql(u8, str[i..], name)) {
            if ((support.no_pct and !pct) or (support.pct and pct)) {
                return .{ .ok = .{ .opt = @intCast(opt), .pct = pct } };
            }
            return .{ .err = .{ .str = str, .what = .unsupported } };
        }
    }
    return .{ .err = .{ .str = str, .what = .unknown } };
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
        id: typ.Widget.Id,
        interval: ?typ.Interval = null,
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

    fn fail(note: []const u8, field: Split) @This() {
        return .{ .err = .{ .note = note, .field = field } };
    }
};

fn parseLine(tmp: *umem.Region, line: []const u8) !ParseLineResult {
    var result: ParseLineResult = undefined;

    var want: ParseWant = .identifier;
    var fields: Splitter = .init(line);
    while (fields.next()) |split| {
        const field = line[split.beg..split.end];

        switch (want) {
            .identifier => {
                if (typ.strWid(field)) |wid| {
                    result = .{ .widget = .{ .id = wid } };
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
                    result.widget.interval = .init(ok);
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
                const sep = mem.indexOfScalarPos(u8, field, 0, ':') orelse
                    return .fail("missing threshold", split);
                const thresh = fmt.parseUnsigned(u8, field[0..sep], 10) catch |e| switch (e) {
                    error.Overflow,
                    error.InvalidCharacter,
                    => return .fail("bad threshold", split),
                };
                if (thresh > 100) return .fail("threshold too big (0..100)", split);

                const hex = field[sep + 1 ..];
                if (color.acceptHex(hex)) |ok| {
                    const ptr = try tmp.pushVec(&result.color.data.?.active.pairs, .front);
                    ptr.* = .init(thresh, ok);
                } else if (hex.len == 0 or mem.eql(u8, hex, "default")) {
                    const ptr = try tmp.pushVec(&result.color.data.?.active.pairs, .front);
                    ptr.* = .initDefault(thresh);
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

pub fn defaultConfig(reg: *umem.Region) []typ.Widget {
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
        \\TIME 20 arg "%A %d.%m ~ %H:%M:%S" format "{time}"
        \\FG bb9
    ;
    var buffer: uio.Buffer = .fixed(config);
    var scratch: [128]u8 align(16) = undefined;
    const ret = parse(reg, &buffer, &scratch) catch unreachable;
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

    fn fail(
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

pub const ParseError = error{
    NoSpaceLeft,
    NoNewline,
    ReadError,
};

pub fn parse(
    reg: *umem.Region,
    buffer: *uio.Buffer,
    scratch: []align(16) u8,
) ParseError!ParseResult {
    const bentry = reg.save(u8, .back);

    var widgets: []typ.Widget = &.{};
    var current: *typ.Widget = undefined;

    var line_nr: usize = 0;
    var reader: uio.LineReader = .init(buffer);
    while (true) {
        const line_ = reader.readLine() catch |e| switch (e) {
            error.EOF => break,
            else => |err| return err,
        };
        line_nr += 1;

        const line = ustr.trimWhitespace(line_);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var tmp: umem.Region = .init(scratch, "cfg_tmp");

        switch (try parseLine(&tmp, line)) {
            .widget => |wi| {
                current = try reg.pushVec(&widgets, .back);
                current.* = .initDefault(wi.id, undefined);
                if (wi.interval) |ok| {
                    current.interval = ok;
                } else {
                    return .fail("widget requires interval", line, line_nr, .zero);
                }
                const arg = blk: {
                    if (current.id.checkCastTo(typ.Widget.Id.RequiresArg)) |_| {
                        if (wi.arg) |ok| break :blk line[ok.beg..ok.end];
                        return .fail("widget requires arg parameter", line, line_nr, .zero);
                    }
                    break :blk undefined;
                };
                const fmt_str, const fmt_split = blk: {
                    if (wi.format) |ok| break :blk .{ line[ok.beg..ok.end], ok };
                    return .fail("widget requires format parameter", line, line_nr, .zero);
                };
                const format = switch (try acceptFormat(reg, fmt_str, current.id)) {
                    .ok => |f| f,
                    .err => |e| {
                        return .fail(e.note, line, line_nr, .{
                            .beg = fmt_split.beg + e.field.beg,
                            .end = fmt_split.beg + e.field.end,
                        });
                    },
                };
                current.format = format;
                // zig fmt: off
                const base = reg.head.ptr;
                current.data = switch (current.id) {
                    .TIME => .{ .TIME = try .init(reg, arg) },
                    .MEM  => .{ .MEM  = undefined },
                    .CPU  => .{ .CPU  = try .init(reg, format, base) },
                    .DISK => .{ .DISK = try .init(reg, arg, format, base) },
                    .NET  => .{ .NET  = try .init(reg, arg, format, base) },
                    .BAT  => .{ .BAT  = try .init(reg, arg) },
                    .READ => .{ .READ = try .init(reg, arg) },
                };
                // zig fmt: on
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
                        const wid = current.id.checkCastTo(typ.Widget.Id.ActiveColorSupported) orelse
                            return .fail(
                                "bad hex: widget doesn't support thresh:#hex pairs",
                                line,
                                line_nr,
                                active.opt,
                            );
                        const name = line[active.opt.beg..active.opt.end];
                        const opt, const opt_pct = switch (strColorOpt(wid, name)) {
                            .ok => |ok| .{ ok.opt, ok.pct },
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
                        const sp = reg.save(T, .front);
                        const ptr = try reg.allocMany(T, active.pairs.len, .front);
                        @memcpy(ptr, active.pairs);

                        switch (co.type) {
                            .fg => {
                                current.fg = .{
                                    .active = .{
                                        .opt = opt,
                                        .pct = opt_pct,
                                        .pairs = .{
                                            .off = @intCast(sp.off),
                                            .len = @intCast(active.pairs.len),
                                        },
                                    },
                                };
                            },
                            .bg => {
                                current.bg = .{
                                    .active = .{
                                        .opt = opt,
                                        .pct = opt_pct,
                                        .pairs = .{
                                            .off = @intCast(sp.off),
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

    // Get a reference to widgets allocated at the back, essentially
    // a `widgets.ptr` but as an offset from `reg.head.ptr`.
    const bexit = reg.save(u8, .back);

    // Mark as free, restoring the region to the state at function's entry.
    reg.restore(bentry);

    // Move widgets from the back to the front, so we may have a chance
    // of fitting everything tightly in a single memory page.
    const ret = reg.allocMany(typ.Widget, widgets.len, .front) catch unreachable;
    @memmove(ret[0..widgets.len], widgets);
    @memset(reg.head[bexit.off..bentry.off], 0);

    return .{ .ok = ret };
}

fn testParse(comptime str: []const u8, reg: *umem.Region, scratch: []align(16) u8) !ParseResult {
    var buffer: uio.Buffer = .fixed(str);
    return try parse(reg, &buffer, scratch);
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
    var reg: umem.Region = .init(&buf, "cfgtest");
    var scratch: [256]u8 align(16) = undefined;

    var r = try testParse("\n", &reg, &scratch);
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

    r = try testParse("TIME 1962 arg \"%A %d.%m ~ %H:%M:%S\" format \"{time}\"\nFG 2a", &reg, &scratch);
    try testDiag(r, "bad hex: widget doesn't support thresh:#hex pairs", 2, .{ .beg = 3, .end = 5 });

    r = try testParse("TIME 1962 arg \"%A %d.%m ~ %H:%M:%S\" format \"{time}\"\nFG 2ab", &reg, &scratch);
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
