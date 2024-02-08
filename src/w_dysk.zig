const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;

const ColorHandler = struct {
    used_kb: u64,
    free_kb: u64,
    avail_kb: u64,
    total_kb: u64,

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            switch (@as(typ.DiskOpt, @enumFromInt(mc.opt))) {
                .@"%used" => utl.percentOf(self.used_kb, self.total_kb),
                .@"%free" => utl.percentOf(self.free_kb, self.total_kb),
                .@"%available" => utl.percentOf(self.avail_kb, self.total_kb),
                .used, .total, .free, .available, .@"-" => unreachable,
            }.val.roundAndTruncate(),
            mc.colors,
        );
    }
};

pub fn widget(
    stream: anytype,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    var buf: [typ.WIDGET_BUF_MAX / 2]u8 = undefined;

    const mountpoint = utl.zeroTerminate(&buf, wf.parts[0]) orelse utl.fatal(
        &.{"DISK: mountpoint path too long"},
    );

    // TODO: use statvfs instead of this
    var res: c.struct_statfs = undefined;
    if (c.statfs(mountpoint, &res) != 0)
        utl.fatal(&.{ "DISK: bad mountpoint: ", mountpoint });

    // convert block size to 1K for calculations
    if (res.f_bsize == 4096) {
        res.f_bsize = 1024;
        res.f_blocks *= 4;
        res.f_bfree *= 4;
        res.f_bavail *= 4;
    } else {
        while (res.f_bsize < 1024) {
            res.f_bsize *= 2;
            res.f_blocks /= 2;
            res.f_bfree /= 2;
            res.f_bavail /= 2;
        }
        while (res.f_bsize > 1024) {
            res.f_bsize /= 2;
            res.f_blocks *= 2;
            res.f_bfree *= 2;
            res.f_bavail *= 2;
        }
    }

    const total_kb = res.f_blocks;
    const free_kb = res.f_bfree;
    const avail_kb = res.f_bavail;
    const used_kb = res.f_blocks - res.f_bavail;

    const writer = stream.writer();
    const ch = ColorHandler{
        .used_kb = used_kb,
        .free_kb = free_kb,
        .avail_kb = avail_kb,
        .total_kb = total_kb,
    };

    utl.writeBlockStart(writer, fg.getColor(ch), bg.getColor(ch));
    utl.writeStr(writer, wf.parts[1]);
    for (wf.iterOpts()[1..], wf.iterParts()[2..]) |*opt, *part| {
        const nu = switch (@as(typ.DiskOpt, @enumFromInt(opt.opt))) {
            .@"%used" => utl.percentOf(used_kb, total_kb),
            .@"%free" => utl.percentOf(free_kb, total_kb),
            .@"%available" => utl.percentOf(avail_kb, total_kb),
            .used => utl.kbToHuman(used_kb),
            .total => utl.kbToHuman(total_kb),
            .free => utl.kbToHuman(free_kb),
            .available => utl.kbToHuman(avail_kb),
            .@"-" => unreachable,
        };
        nu.write(writer, opt.alignment, opt.precision);
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
