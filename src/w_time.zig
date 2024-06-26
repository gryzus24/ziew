const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const utl = @import("util.zig");
const c = utl.c;

pub fn widget(
    stream: anytype,
    strftime_fmt: [*:0]const u8,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    var timebuf: [32]u8 = undefined;
    var tm: c.struct_tm = undefined;

    _ = c.localtime_r(&c.time(null), &tm);

    utl.writeBlockStart(stream, fg.getDefault(), bg.getDefault());
    const nwritten = c.strftime(&timebuf, timebuf.len, strftime_fmt, &tm);
    if (nwritten == 0) {
        utl.writeStr(stream, "<empty>");
    } else {
        utl.writeStr(stream, timebuf[0..nwritten]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
