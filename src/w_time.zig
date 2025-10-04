const std = @import("std");
const c = @import("c.zig").c;
const color = @import("color.zig");
const typ = @import("type.zig");

const udiv = @import("util/div.zig");
const uio = @import("util/io.zig");
const ustr = @import("util/str.zig");

const io = std.io;
const linux = std.os.linux;
const mem = std.mem;

// == public ==================================================================

pub noinline fn widget(
    writer: *io.Writer,
    w: *const typ.Widget,
    base: [*]const u8,
) void {
    const wd = w.data.TIME;

    var ts: linux.timespec = undefined;
    var tm: c.struct_tm = undefined;

    _ = linux.clock_gettime(.REALTIME, &ts);
    _ = c.localtime_r(&ts.sec, &tm);

    typ.writeWidgetBeg(writer, w.fg.static, w.bg.static);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);
        switch (@as(typ.TimeOpt, @enumFromInt(part.opt))) {
            .arg => uio.writeStr(writer, mem.sliceTo(wd.getStrf(), 0)),
            .time => {
                const dst = writer.buffer[writer.end..];
                const nr_written = c.strftime(dst.ptr, dst.len, wd.getStrf(), &tm);
                writer.end += nr_written;
            },
            .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" => {
                const DIVS: [9]u32 = comptime .{
                    100_000_000, 10_000_000, 1_000_000,
                    100_000,     10_000,     1_000,
                    100,         10,         1,
                };
                const DIVIDEND_MAX = 1_000_000_000;
                const MULT_SHFT: [9]udiv.MultShft = comptime .{
                    udiv.DivConstant(DIVS[0], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[1], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[2], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[3], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[4], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[5], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[6], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[7], DIVIDEND_MAX),
                    udiv.DivConstant(DIVS[8], DIVIDEND_MAX),
                };
                var cur: u64 = @intCast(ts.nsec);

                var n = @min(part.opt, writer.unusedCapacityLen());
                const dst = writer.buffer[writer.end..];

                var i: usize = 0;
                while (n >= 2) {
                    const ms = MULT_SHFT[i + 1];
                    const q, cur = udiv.multShiftDivMod(cur, ms, DIVS[i + 1]);
                    dst[i..][0..2].* = ustr.digits2_lut(q);
                    i += 2;
                    n -= 2;
                }
                if (n == 1) {
                    const ms = MULT_SHFT[i];
                    const q, _ = udiv.multShiftDivMod(cur, ms, DIVS[i]);
                    dst[i] = '0' | @as(u8, @intCast(q));
                    i += 1;
                }
                writer.end += i;
            },
        }
    }
    wd.format.last_str.writeBytes(writer, base);
}
