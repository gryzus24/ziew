const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const c = utl.c;
const io = std.io;

const ColorHandler = struct {
    used_kb: u64,
    free_kb: u64,
    avail_kb: u64,
    total_kb: u64,

    pub fn checkPairs(self: @This(), ac: color.Color.Active) color.Color.Data {
        return color.firstColorGEThreshold(
            switch (@as(typ.DiskOpt.ColorSupported, @enumFromInt(ac.opt))) {
                .@"%used" => unt.Percent(self.used_kb, self.total_kb),
                .@"%free" => unt.Percent(self.free_kb, self.total_kb),
                .@"%available" => unt.Percent(self.avail_kb, self.total_kb),
            }.n.roundAndTruncate(),
            ac.pairs,
        );
    }
};

// == public ==================================================================

pub fn widget(writer: *io.Writer, w: *const typ.Widget) []const u8 {
    const wd = w.wid.DISK;

    // TODO: use statvfs instead of this
    var sfs: c.struct_statfs = undefined;
    if (c.statfs(wd.mountpoint, &sfs) != 0) {
        const noop: color.Color.NoopIndirect = .{};
        utl.writeBlockBeg(writer, wd.fg.get(noop), wd.bg.get(noop));
        utl.writeStr(writer, wd.mountpoint);
        utl.writeStr(writer, ": <not mounted>");
        return utl.writeBlockEnd(writer);
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

    const ch: ColorHandler = .{
        .used_kb = used_kb,
        .free_kb = free_kb,
        .avail_kb = avail_kb,
        .total_kb = total_kb,
    };

    utl.writeBlockBeg(writer, wd.fg.get(ch), wd.bg.get(ch));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(writer, part.str);

        const diskopt: typ.DiskOpt = @enumFromInt(part.opt);
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
        }).write(writer, part.wopts, part.flags.quiet);
    }
    utl.writeStr(writer, wd.format.part_last);
    return utl.writeBlockEnd(writer);
}
