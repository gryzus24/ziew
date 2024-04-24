const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const ascii = std.ascii;
const fs = std.fs;
const mem = std.mem;

fn writeBlockError(
    fbs: anytype,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
    prefix: []const u8,
    msg: []const u8,
) []const u8 {
    utl.writeBlockStart(fbs, fg.getDefault(), bg.getDefault());
    utl.writeStr(fbs, prefix);
    utl.writeStr(fbs, ": ");
    utl.writeStr(fbs, msg);
    return utl.writeBlockEnd_GetWritten(fbs);
}

fn acceptColor(str: []const u8, pos: *usize) ?color.Color {
    const start = utl.skipChars(str, &ascii.whitespace);
    var i: usize = start;
    defer pos.* += i;

    if (start == str.len) return null;
    if (str[i] != '#') return null;
    i += 1;

    while (i < str.len and !ascii.isWhitespace(str[i])) : (i += 1) {}

    return color.Color.init(0, str[start..i]) catch null;
}

pub fn widget(
    stream: anytype,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    var _buf: [typ.WIDGET_BUF_MAX]u8 = undefined;

    const filepath = utl.zeroTerminate(&_buf, wf.parts[0]) orelse utl.fatal(
        &.{"READ: filepath too long"},
    );
    const basename = fs.path.basename(wf.parts[0]);

    const file = fs.cwd().openFileZ(filepath, .{}) catch |err| {
        return writeBlockError(stream, fg, bg, basename, @errorName(err));
    };
    defer file.close();

    const nread = file.read(&_buf) catch |err| {
        utl.fatal(&.{ "READ: read: ", basename, @errorName(err) });
    };

    var pos: usize = 0;
    const end = mem.indexOfAny(u8, _buf[0..nread], ascii.whitespace[1..]) orelse nread;
    const content = _buf[0..end];
    var fghex: ?*const [7]u8 = fg.getDefault();
    var bghex: ?*const [7]u8 = bg.getDefault();

    for (wf.iterOpts()[1..]) |*opt| {
        if (@as(typ.ReadOpt, @enumFromInt(opt.opt)) == .content) {
            if (acceptColor(content[pos..], &pos)) |*f| fghex = f.getHex();
            if (acceptColor(content[pos..], &pos)) |*b| bghex = b.getHex();
            if (pos < end and ascii.isWhitespace(content[pos])) pos += 1;
            break;
        }
    }

    utl.writeBlockStart(stream, fghex, bghex);
    utl.writeStr(stream, wf.parts[1]);
    for (wf.iterOpts()[1..], wf.iterParts()[2..]) |*opt, *part| {
        const str = switch (@as(typ.ReadOpt, @enumFromInt(opt.opt))) {
            .basename => basename,
            .content => content[pos..],
            .raw => content[0..],
            .@"-" => unreachable,
        };
        utl.writeStr(stream, str);
        utl.writeStr(stream, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
