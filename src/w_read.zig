const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");

const uio = @import("util/io.zig");

const mem = std.mem;

// == private =================================================================

fn acceptColor(
    buf: []const u8,
    i: usize,
    tag: color.Hex.Tag,
) struct { color.Hex, usize } {
    var j = i;
    while (j < buf.len and buf[j] <= ' ') : (j += 1) {}
    if (j == buf.len or buf[j] != '#') return .{ .empty, j };

    const k = j;
    while (j < buf.len and buf[j] > ' ') : (j += 1) {}
    if (color.acceptHex(buf[k..j])) |ok| {
        return .{ .init(tag, ok), j };
    }
    return .{ .empty, j };
}

fn openAndRead(path: [*:0]const u8, buf: []u8) ![]const u8 {
    const fd = try uio.open0(path);
    defer uio.close(fd);
    const n = try uio.pread(fd, buf, .single);
    return buf[0 .. mem.findScalarPos(u8, buf[0..n], 0, '\n') orelse n];
}

// == public ==================================================================

pub fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    parts: []const typ.Format.Part,
    base: [*]const u8,
) void {
    const wd = w.getDataConst(.READ, base);
    const path, const basename = .{ wd.path.get(), wd.getBasename() };

    var buf: [typ.WIDGET_BUF_WRITABLE]u8 = undefined;

    const data = openAndRead(path, &buf) catch |e| {
        typ.writeWidgetBeg(writer, w.fg.static, w.bg.static);
        uio.writeStr(writer, basename);
        uio.writeStr(writer, ": ");
        uio.writeStr(writer, @errorName(e));
        return;
    };

    var pos: usize = 0;
    var fg = w.fg.static;
    var bg = w.bg.static;

    for (parts) |*part| {
        const opt: typ.Opts.Read = @enumFromInt(part.opt);
        if (opt == .content) {
            fg, pos = acceptColor(data, pos, .fg);
            bg, pos = acceptColor(data, pos, .bg);
            if (pos < data.len and data[pos] <= ' ') pos += 1;
            break;
        }
    }

    typ.writeWidgetBeg(writer, fg, bg);
    for (parts) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.Opts.Read = @enumFromInt(part.opt);

        var src = data;
        if (opt == .content)
            src = data[pos..];
        if (opt == .basename)
            src = basename;

        uio.writeStr(writer, src);
    }
}
