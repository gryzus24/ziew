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

    var buf: [32]u8 = undefined;
    var ts: linux.timespec = undefined;
    var tm: c.struct_tm = undefined;

    _ = linux.clock_gettime(.REALTIME, &ts);
    _ = c.localtime_r(&ts.sec, &tm);

    utl.writeWidgetBeg(writer, w.fg.static, w.bg.static);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);
        const str = switch (@as(typ.TimeOpt, @enumFromInt(part.opt))) {
            .arg => mem.sliceTo(&wd.strf, 0),
            .time => blk: {
                const nr_written = c.strftime(&buf, buf.len, wd.getStrf(), &tm);
                if (nr_written == 0) {
                    @branchHint(.cold);
                    break :blk "<empty>";
                } else {
                    break :blk buf[0..nr_written];
                }
            },
            .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" => blk: {
                const DIV: [9]u32 = .{
                    100_000_000, 10_000_000, 1_000_000,
                    100_000,     10_000,     1_000,
                    100,         10,         1,
                };
                const nsec: u32 = @intCast(ts.nsec);

                var i: usize = 0;
                var rem = part.opt;
                while (rem >= 2) {
                    buf[i..][0..2].* = utl.digits2_lut((nsec / DIV[i + 1]) % 100);
                    i += 2;
                    rem -= 2;
                }
                if (rem == 1) {
                    buf[i] = '0' | @as(u8, @intCast((nsec / DIV[i]) % 10));
                    i += 1;
                }
                break :blk buf[0..i];
            },
        };
        utl.writeStr(writer, str);
    }
    wd.format.last_str.writeBytes(writer, base);
}
