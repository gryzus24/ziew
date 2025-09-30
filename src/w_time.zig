const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;
const io = std.io;
const linux = std.os.linux;
const mem = std.mem;

// == public ==================================================================

pub noinline fn widget(writer: *io.Writer, w: *const typ.Widget, base: [*]const u8) void {
    const wd = w.wid.TIME;

    var ts: linux.timespec = undefined;
    var tm: c.struct_tm = undefined;

    _ = linux.clock_gettime(.REALTIME, &ts);
    _ = c.localtime_r(&ts.sec, &tm);

    utl.writeWidgetBeg(writer, w.fg.static, w.bg.static);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);
        switch (@as(typ.TimeOpt, @enumFromInt(part.opt))) {
            .arg => utl.writeStr(writer, mem.sliceTo(wd.getStrf(), 0)),
            .time => {
                const dst = writer.unusedCapacitySlice();
                const nr_written = c.strftime(dst.ptr, dst.len, wd.getStrf(), &tm);
                writer.end += nr_written;
            },
            .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" => {
                const DIV: [9]u32 = .{
                    100_000_000, 10_000_000, 1_000_000,
                    100_000,     10_000,     1_000,
                    100,         10,         1,
                };
                const nsec: u32 = @intCast(ts.nsec);
                const dst = writer.unusedCapacitySlice();

                var i: usize = 0;
                var nr_to_write = @min(part.opt, dst.len);
                while (nr_to_write >= 2) {
                    const n = (nsec / DIV[i + 1]) % 100;
                    dst[i..][0..2].* = utl.digits2_lut(n);
                    i += 2;
                    nr_to_write -= 2;
                }
                if (nr_to_write == 1) {
                    const n = (nsec / DIV[i]) % 10;
                    dst[i] = '0' | @as(u8, @intCast(n));
                    i += 1;
                }
                writer.end += i;
            },
        }
    }
    wd.format.last_str.writeBytes(writer, base);
}
