const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;

// == public ==================================================================

pub fn widget(stream: anytype, w: *const typ.Widget) []const u8 {
    const wd = w.wid.TIME;

    var outbuf: [typ.STRFTIME_OUT_BUF_SIZE_MAX]u8 = undefined;
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
