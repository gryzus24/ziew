const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const c = utl.c;

const ColorHandler = struct {
    used_kb: u64,
    free_kb: u64,
    avail_kb: u64,
    total_kb: u64,

    pub fn checkOptColors(self: @This(), oc: typ.OptColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            switch (@as(typ.DiskOpt.ColorSupported, @enumFromInt(oc.opt))) {
                .@"%used" => unt.Percent(self.used_kb, self.total_kb),
                .@"%free" => unt.Percent(self.free_kb, self.total_kb),
                .@"%available" => unt.Percent(self.avail_kb, self.total_kb),
            }.n.roundAndTruncate(),
            oc.colors,
        );
    }
};

// == public ==================================================================

pub const WidgetData = struct {
    mountpoint: [:0]const u8,
    format: typ.Format = .{},
    fg: typ.Color = .nocolor,
    bg: typ.Color = .nocolor,

    pub fn init(reg: *m.Region, arg: []const u8) !*WidgetData {
        if (arg.len >= typ.WIDGET_BUF_MAX)
            utl.fatal(&.{"DISK: mountpoint path too long"});

        const retptr = try reg.frontAlloc(WidgetData);

        retptr.* = .{ .mountpoint = try reg.frontWriteStrZ(arg) };
        return retptr;
    }
};

pub fn widget(stream: anytype, w: *const typ.Widget) []const u8 {
    const wd = w.wid.DISK;

    // TODO: use statvfs instead of this
    var sfs: c.struct_statfs = undefined;
    if (c.statfs(wd.mountpoint, &sfs) != 0) {
        utl.writeBlockStart(stream, wd.fg.getDefault(), wd.bg.getDefault());
        utl.writeStr(stream, wd.mountpoint);
        utl.writeStr(stream, ": <not mounted>");
        return utl.writeBlockEnd_GetWritten(stream);
    }

    // convert block size to 1K for calculations
    if (sfs.f_bsize == 4096) {
        sfs.f_bsize = 1024;
        sfs.f_blocks *= 4;
        sfs.f_bfree *= 4;
        sfs.f_bavail *= 4;
    } else {
        while (sfs.f_bsize < 1024) {
            sfs.f_bsize *= 2;
            sfs.f_blocks /= 2;
            sfs.f_bfree /= 2;
            sfs.f_bavail /= 2;
        }
        while (sfs.f_bsize > 1024) {
            sfs.f_bsize /= 2;
            sfs.f_blocks *= 2;
            sfs.f_bfree *= 2;
            sfs.f_bavail *= 2;
        }
    }

    const total_kb = sfs.f_blocks;
    const free_kb = sfs.f_bfree;
    const avail_kb = sfs.f_bavail;
    const used_kb = sfs.f_blocks - sfs.f_bavail;

    const writer = stream.writer();
    const ch: ColorHandler = .{
        .used_kb = used_kb,
        .free_kb = free_kb,
        .avail_kb = avail_kb,
        .total_kb = total_kb,
    };

    utl.writeBlockStart(writer, wd.fg.getColor(ch), wd.bg.getColor(ch));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(writer, part.part);

        const diskopt = @as(typ.DiskOpt, @enumFromInt(part.opt));
        if (diskopt == .arg) {
            utl.writeStr(writer, wd.mountpoint);
            continue;
        }
        (switch (diskopt) {
            // zig fmt: off
            .arg           => unreachable,
            .@"%used"      => unt.Percent(used_kb, total_kb),
            .@"%free"      => unt.Percent(free_kb, total_kb),
            .@"%available" => unt.Percent(avail_kb, total_kb),
            .total         => unt.SizeKb(total_kb),
            .used          => unt.SizeKb(used_kb),
            .free          => unt.SizeKb(free_kb),
            .available     => unt.SizeKb(avail_kb),
            // zig fmt: on
        }).write(writer, part.wopts);
    }
    utl.writeStr(writer, wd.format.part_last);
    return utl.writeBlockEnd_GetWritten(stream);
}
