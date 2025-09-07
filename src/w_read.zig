const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const ascii = std.ascii;
const fs = std.fs;
const io = std.io;
const mem = std.mem;

// == private =================================================================

const FILE_END_MARKERS = ascii.whitespace[1..] ++ .{'\x00'};
comptime {
    if (mem.indexOfScalar(u8, FILE_END_MARKERS, ' ') != null)
        @compileError("0x20 in file end markers");
}

fn writeBlockError(
    writer: *io.Writer,
    fg: ?*const [7]u8,
    bg: ?*const [7]u8,
    prefix: []const u8,
    msg: []const u8,
) []const u8 {
    utl.writeBlockBeg(writer, fg, bg);
    utl.writeStr(writer, prefix);
    utl.writeStr(writer, ": ");
    utl.writeStr(writer, msg);
    return utl.writeBlockEnd(writer);
}

fn acceptHex(str: []const u8, pos: *usize) ?color.Hex {
    var i: usize = 0;
    defer pos.* += i;

    i = utl.skipSpacesTabs(str, i) orelse return null;
    const beg = i;

    if (str[i] != '#') return null;
    i += 1;
    i = mem.indexOfAnyPos(u8, str, i, " \t") orelse str.len;

    var hex: color.Hex = .{};
    _ = hex.set(str[beg..i]);
    return hex;
}

fn readFileUntil(file: fs.File, endmarkers: []const u8, buf: *[typ.WIDGET_BUF_MAX]u8) ![]const u8 {
    const n = try file.read(buf);
    const end = mem.indexOfAny(u8, buf[0..n], endmarkers) orelse n;
    return buf[0..end];
}

// == public ==================================================================

pub fn widget(writer: *io.Writer, w: *const typ.Widget) []const u8 {
    const wd = w.wid.READ;

    const file = fs.cwd().openFileZ(wd.path, .{}) catch |e| {
        return writeBlockError(writer, wd.fg.get(), wd.bg.get(), wd.basename, @errorName(e));
    };
    defer file.close();

    var _buf: [typ.WIDGET_BUF_MAX]u8 = undefined;
    const content = readFileUntil(file, FILE_END_MARKERS, &_buf) catch |e| {
        utl.fatal(&.{ "READ: read: ", wd.basename, @errorName(e) });
    };

    var pos: usize = 0;
    var fghex: color.Hex = wd.fg;
    var bghex: color.Hex = wd.bg;

    for (wd.format.part_opts) |*part| {
        if (@as(typ.ReadOpt, @enumFromInt(part.opt)) == .content) {
            if (acceptHex(content[pos..], &pos)) |fg| fghex = fg;
            if (acceptHex(content[pos..], &pos)) |bg| bghex = bg;
            if (pos < content.len and ascii.isWhitespace(content[pos])) pos += 1;
            break;
        }
    }

    utl.writeBlockBeg(writer, fghex.get(), bghex.get());
    for (wd.format.part_opts) |*part| {
        utl.writeStr(writer, part.str);
        utl.writeStr(
            writer,
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
    utl.writeStr(writer, wd.format.part_last);
    return utl.writeBlockEnd(writer);
}
