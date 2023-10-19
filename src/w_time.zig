const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const utl = @import("util.zig");
const c = utl.c;

pub fn widget(
    stream: anytype,
    strftime_fmt: [:0]const u8,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    const tm = c.localtime(&c.time(null));
    var timebuf: [32]u8 = undefined;

    utl.writeBlockStart(
        stream,
        color.defaultColorFromColorUnion(fg),
        color.defaultColorFromColorUnion(bg),
    );
    const nwritten = c.strftime(&timebuf, timebuf.len, strftime_fmt, tm);
    if (nwritten == 0) {
        const surrogate = "<empty>";
        utl.writeStr(stream, surrogate);
    } else {
        utl.writeStr(stream, timebuf[0..nwritten]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
