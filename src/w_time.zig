const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;
const io = std.io;

// == public ==================================================================

pub fn widget(writer: *io.Writer, w: *const typ.Widget) []const u8 {
    const wd = w.wid.TIME;

    var outbuf: [typ.STRFTIME_OUT_BUF_SIZE_MAX]u8 = undefined;
    var tm: c.struct_tm = undefined;

    _ = c.localtime_r(&c.time(null), &tm);

    utl.writeBlockBeg(writer, w.fg.static, w.bg.static);
    const nr_written = c.strftime(&outbuf, outbuf.len, wd.format, &tm);
    if (nr_written == 0) {
        @branchHint(.unlikely);
        utl.writeStr(writer, "<empty>");
    } else {
        utl.writeStr(writer, outbuf[0..nr_written]);
    }
    return utl.writeBlockEnd(writer);
}
