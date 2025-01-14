const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const ascii = std.ascii;
const fs = std.fs;
const mem = std.mem;

// == private =================================================================

const FILE_END_MARKERS = ascii.whitespace[1..] ++ .{'\x00'};
comptime {
    if (mem.indexOfScalar(u8, FILE_END_MARKERS, ' ') != null)
        @compileError("0x20 in file end markers");
}

fn writeBlockError(
    fbs: anytype,
    fg: ?*const [7]u8,
    bg: ?*const [7]u8,
    prefix: []const u8,
    msg: []const u8,
) []const u8 {
    utl.writeBlockStart(fbs, fg, bg);
    utl.writeStr(fbs, prefix);
    utl.writeStr(fbs, ": ");
    utl.writeStr(fbs, msg);
    return utl.writeBlockEnd_GetWritten(fbs);
}

fn acceptHex(str: []const u8, pos: *usize) ?typ.Hex {
    var i: usize = 0;
    defer pos.* += i;

    i = utl.skipSpacesTabs(str, i) orelse return null;
    const beg = i;

    if (str[i] != '#') return null;
    i += 1;
    i = mem.indexOfAnyPos(u8, str, i, " \t") orelse str.len;

    var hex: typ.Hex = .{};
    _ = hex.set(str[beg..i]);
    return hex;
}

fn readFileUntil(file: fs.File, endmarkers: []const u8, buf: *[typ.WIDGET_BUF_MAX]u8) ![]const u8 {
    const n = try file.read(buf);
    const end = mem.indexOfAny(u8, buf[0..n], endmarkers) orelse n;
    return buf[0..end];
}

// == public ==================================================================

pub const WidgetData = struct {
    path: [:0]const u8,
    basename: []const u8,
    format: typ.Format = .{},
    fg: typ.Hex = .{},
    bg: typ.Hex = .{},

    pub fn init(reg: *m.Region, arg: []const u8) !*WidgetData {
        if (arg.len >= typ.WIDGET_BUF_MAX)
            utl.fatal(&.{"READ: path too long"});

        const retptr = try reg.frontAlloc(WidgetData);

        retptr.* = .{
            .path = try reg.frontWriteStrZ(arg),
            .basename = fs.path.basename(arg),
        };
        return retptr;
    }
};

pub fn widget(stream: anytype, w: *const typ.Widget) []const u8 {
    const wd = w.wid.READ;

    const file = fs.cwd().openFileZ(wd.path, .{}) catch |e| {
        return writeBlockError(stream, wd.fg.get(), wd.bg.get(), wd.basename, @errorName(e));
    };
    defer file.close();

    var _buf: [typ.WIDGET_BUF_MAX]u8 = undefined;
    const content = readFileUntil(file, FILE_END_MARKERS, &_buf) catch |e| {
        utl.fatal(&.{ "READ: read: ", wd.basename, @errorName(e) });
    };

    var pos: usize = 0;
    var fghex: typ.Hex = wd.fg;
    var bghex: typ.Hex = wd.bg;

    for (wd.format.part_opts) |*part| {
        if (@as(typ.ReadOpt, @enumFromInt(part.opt)) == .content) {
            if (acceptHex(content[pos..], &pos)) |fg| fghex = fg;
            if (acceptHex(content[pos..], &pos)) |bg| bghex = bg;
            if (pos < content.len and ascii.isWhitespace(content[pos])) pos += 1;
            break;
        }
    }

    utl.writeBlockStart(stream, fghex.get(), bghex.get());
    for (wd.format.part_opts) |*part| {
        utl.writeStr(stream, part.part);
        utl.writeStr(
            stream,
            switch (@as(typ.ReadOpt, @enumFromInt(part.opt))) {
                // zig fmt: off
                .arg      => wd.path,
                .basename => wd.basename,
                .content  => content[pos..],
                .raw      => content[0..],
                // zig fmt: on
            },
        );
    }
    utl.writeStr(stream, wd.format.part_last);
    return utl.writeBlockEnd_GetWritten(stream);
}
