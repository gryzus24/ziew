const std = @import("std");
const cfg = @import("config.zig");
const utl = @import("util.zig");
const c = utl.c;

pub fn widget(
    stream: anytype,
    strftime_fmt: [:0]const u8,
    fg: *const cfg.ColorUnion,
    bg: *const cfg.ColorUnion,
) []const u8 {
    const tm = c.localtime(&c.time(null));
    var timebuf: [32]u8 = undefined;

    const fg_hex = switch (fg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => unreachable,
    };
    const bg_hex = switch (bg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => unreachable,
    };
    utl.writeBlockStart(stream, fg_hex, bg_hex);
    const nwritten = c.strftime(&timebuf, timebuf.len, strftime_fmt, tm);
    if (nwritten == 0) {
        const surrogate = "<empty>";
        utl.writeStr(stream, surrogate);
    } else {
        utl.writeStr(stream, timebuf[0..nwritten]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
