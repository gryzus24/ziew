const std = @import("std");
const c = @import("c.zig").c;
const color = @import("color.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const iou = @import("util/io.zig");

const io = std.io;

const ColorHandler = struct {
    used_kb: u64,
    free_kb: u64,
    avail_kb: u64,
    total_kb: u64,

    pub fn checkPairs(self: @This(), ac: color.Active, base: [*]const u8) color.Hex {
        return color.firstColorGEThreshold(
            switch (@as(typ.DiskOpt.ColorSupported, @enumFromInt(ac.opt))) {
                .@"%used" => unt.Percent(self.used_kb, self.total_kb),
                .@"%free" => unt.Percent(self.free_kb, self.total_kb),
                .@"%available" => unt.Percent(self.avail_kb, self.total_kb),
            }.n.roundU24AndTruncate(),
            ac.pairs.get(base),
        );
    }
};

// == public ==================================================================

pub noinline fn widget(writer: *io.Writer, w: *const typ.Widget, base: [*]const u8) void {
    const wd = w.data.DISK;

    // TODO: use statvfs instead of this
    var sfs: c.struct_statfs = undefined;
    if (c.statfs(wd.getMountpoint(), &sfs) != 0) {
        const noop: typ.Widget.NoopIndirect = .{};
        const fg, const bg = w.check(noop, base);
        typ.writeWidgetBeg(writer, fg, bg);
        iou.writeStr(writer, wd.getMountpoint());
        iou.writeStr(writer, ": <not mounted>");
        return;
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

    const fg, const bg = w.check(ch, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const diskopt: typ.DiskOpt = @enumFromInt(part.opt);
        if (diskopt == .arg) {
            iou.writeStr(writer, wd.getMountpoint());
            continue;
        }
        const nu = switch (diskopt) {
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
        };
        nu.write(writer, part.wopts, part.quiet);
    }
    wd.format.last_str.writeBytes(writer, base);
}
