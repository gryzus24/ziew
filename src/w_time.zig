const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;

const STRFTIME_FORMAT_BUF_SIZE_MAX = typ.WIDGET_BUF_MAX / 4;
const STRFTIME_OUT_BUF_SIZE_MAX = STRFTIME_FORMAT_BUF_SIZE_MAX * 2;

// == public ==================================================================

pub const WidgetData = struct {
    format: [:0]const u8,
    fg: typ.Hex = .{},
    bg: typ.Hex = .{},

    pub fn init(reg: *m.Region, arg: []const u8) !*WidgetData {
        if (arg.len >= STRFTIME_FORMAT_BUF_SIZE_MAX)
            utl.fatal(&.{"TIME: strftime format too long"});

        const ret = try reg.frontAlloc(WidgetData);

        ret.* = .{ .format = try reg.frontWriteStrZ(arg) };
        return ret;
    }
};

pub fn widget(stream: anytype, w: *const typ.Widget) []const u8 {
    const wd = w.wid.TIME;

    var outbuf: [STRFTIME_OUT_BUF_SIZE_MAX]u8 = undefined;
    var tm: c.struct_tm = undefined;

    _ = c.localtime_r(&c.time(null), &tm);

    utl.writeBlockStart(stream, wd.fg.get(), wd.bg.get());
    const nwritten = c.strftime(&outbuf, outbuf.len, wd.format, &tm);
    if (nwritten == 0) {
        @branchHint(.unlikely);
        utl.writeStr(stream, "<empty>");
    } else {
        utl.writeStr(stream, outbuf[0..nwritten]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
