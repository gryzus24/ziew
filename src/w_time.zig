const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;
const io = std.io;

// == public ==================================================================

pub noinline fn widget(writer: *io.Writer, w: *const typ.Widget) void {
    const wd = w.wid.TIME;

    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&c.time(null), &tm);

    utl.writeWidgetBeg(writer, w.fg.static, w.bg.static);
    const out = writer.unusedCapacitySlice();
    const nr_written = c.strftime(out.ptr, out.len, wd.getFormat(), &tm);
    if (nr_written == 0) {
        @branchHint(.unlikely);
        utl.writeStr(writer, "<empty>");
    } else {
        writer.end += nr_written;
    }
}
