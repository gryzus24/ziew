const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");

const uio = @import("util/io.zig");

const mem = std.mem;

// == private =================================================================

fn acceptColor(buf: []const u8, i: usize) struct { color.Hex, usize } {
    var j = i;
    while (j < buf.len and buf[j] <= ' ') : (j += 1) {}
    if (j == buf.len or buf[j] != '#') return .{ .default, j };

    const k = j;
    while (j < buf.len and buf[j] > ' ') : (j += 1) {}
    if (color.acceptHex(buf[k..j])) |ok| {
        return .{ .init(ok), j };
    }
    return .{ .default, j };
}

fn openAndRead(path: [*:0]const u8, buf: []u8) ![]const u8 {
    const fd = try uio.open0(path);
    defer uio.close(fd);
    const n = try uio.pread(fd, buf, 0);
    return buf[0 .. mem.indexOfScalarPos(u8, buf[0..n], 0, '\n') orelse n];
}

// == public ==================================================================

pub inline fn widget(writer: *uio.Writer, w: *const typ.Widget, base: [*]const u8) void {
    const wd = w.data.READ;

    var buf: [typ.WIDGET_BUF_MAX]u8 = undefined;

    const data = openAndRead(wd.getPath(), &buf) catch |e|
        return typ.writeWidget(
            writer,
            w.fg.static,
            w.bg.static,
            &[3][]const u8{ wd.getBasename(), ": ", @errorName(e) },
        );

    var pos: usize = 0;
    var fg = w.fg.static;
    var bg = w.bg.static;

    for (wd.format.parts.get(base)) |*part| {
        const opt: typ.ReadOpt = @enumFromInt(part.opt);
        if (opt == .content) {
            fg, pos = acceptColor(data, pos);
            bg, pos = acceptColor(data, pos);
            if (pos < data.len and data[pos] <= ' ') pos += 1;
            break;
        }
    }

    typ.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.ReadOpt = @enumFromInt(part.opt);
        const dst = writer.buffer[writer.end..];

        writer.end += switch (opt) {
            .arg => advance: {
                const s = wd.getPath();
                var i: usize = 0;
                while (i < dst.len and s[i] != 0) : (i += 1) dst[i] = s[i];
                break :advance i;
            },
            .basename => advance: {
                const s = wd.getBasename();
                const n = @min(s.len, dst.len);
                var i: usize = 0;
                while (i < n) : (i += 1) dst[i] = s[i];
                break :advance n;
            },
            .content, .raw => advance: {
                const s = data[@intFromBool(opt == .content) * pos ..];
                const n = @min(s.len, dst.len);
                @memcpy(dst[0..n], s[0..n]);
                break :advance n;
            },
        };
    }
    wd.format.last_str.writeBytes(writer, base);
}
