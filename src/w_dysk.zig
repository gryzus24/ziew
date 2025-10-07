const std = @import("std");
const color = @import("color.zig");
const ext = @import("ext.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const uio = @import("util/io.zig");

const Statfs = struct {
    inner: ext.struct_statfs,
    fields: [7]u64,
    opt_mask_pct_ino: typ.OptBit,

    const kb_total = 0;
    const kb_free = 1;
    const kb_avail = 2;
    const kb_used = 3;
    const ino_total = 4;
    const ino_free = 5;
    const ino_used = 6;

    comptime {
        const assert = std.debug.assert;
        assert(kb_total == @intFromEnum(typ.DiskOpt.@"%total"));
        assert(kb_free == @intFromEnum(typ.DiskOpt.@"%free"));
        assert(kb_avail == @intFromEnum(typ.DiskOpt.@"%available"));
        assert(kb_used == @intFromEnum(typ.DiskOpt.@"%used"));
        assert(ino_total == @intFromEnum(typ.DiskOpt.@"%ino_total"));
        assert(ino_free == @intFromEnum(typ.DiskOpt.@"%ino_free"));
        assert(ino_used == @intFromEnum(typ.DiskOpt.@"%ino_used"));
        const size_off = typ.DiskOpt.SIZE_OPTS_OFF;
        assert(kb_total == @intFromEnum(typ.DiskOpt.total) - size_off);
        assert(kb_free == @intFromEnum(typ.DiskOpt.free) - size_off);
        assert(kb_avail == @intFromEnum(typ.DiskOpt.available) - size_off);
        assert(kb_used == @intFromEnum(typ.DiskOpt.used) - size_off);
        assert(ino_total == @intFromEnum(typ.DiskOpt.ino_total) - size_off);
        assert(ino_free == @intFromEnum(typ.DiskOpt.ino_free) - size_off);
        assert(ino_used == @intFromEnum(typ.DiskOpt.ino_used) - size_off);
        const si_ino_off = typ.DiskOpt.SI_INO_OPTS_OFF;
        assert(ino_total == @intFromEnum(typ.DiskOpt.ino_total) - si_ino_off);
        assert(ino_free == @intFromEnum(typ.DiskOpt.ino_free) - si_ino_off);
        assert(ino_used == @intFromEnum(typ.DiskOpt.ino_used) - si_ino_off);
    }

    pub fn checkPairs(self: @This(), ac: color.Active, base: [*]const u8) color.Hex {
        return color.firstColorGEThreshold(
            unt.Percent(
                self.fields[ac.opt],
                self.fields[
                    if (typ.optBit(ac.opt) & self.opt_mask_pct_ino != 0)
                        Statfs.ino_total
                    else
                        Statfs.kb_total
                ],
            ).n.roundU24AndTruncate(),
            ac.pairs.get(base),
        );
    }
};

// == public ==================================================================

pub noinline fn widget(writer: *uio.Writer, w: *const typ.Widget, base: [*]const u8) void {
    const wd = w.data.DISK;

    var sfs: Statfs = .{
        .inner = undefined,
        .fields = undefined,
        .opt_mask_pct_ino = wd.opt_mask.pct_ino,
    };
    while (true) {
        const ret = ext.sys_statfs(wd.getMountpoint(), &sfs.inner);
        if (ret < 0) {
            @branchHint(.unlikely);
            const err = switch (ret) {
                -ext.c.EACCES => "<no access>",
                -ext.c.EFAULT => unreachable,
                -ext.c.EINTR => continue,
                -ext.c.ENAMETOOLONG => unreachable,
                -ext.c.ENOENT, -ext.c.ENOTDIR => "<not mounted>",
                -ext.c.ENOSYS => "<not supported>",
                else => "<unlucky>",
            };
            const handler: typ.Widget.NoopColorHandler = .{};
            const fg, const bg = w.check(handler, base);
            typ.writeWidgetBeg(writer, fg, bg);
            for ([3][]const u8{ wd.getMountpoint(), ": ", err }) |s|
                uio.writeStr(writer, s);
            return;
        }
        break;
    }

    // zig fmt: off
    const f = &sfs.fields;
    f[Statfs.kb_total]  = (sfs.inner.f_bsize * sfs.inner.f_blocks) / 1024;
    f[Statfs.kb_free]   = (sfs.inner.f_bsize * sfs.inner.f_bfree) / 1024;
    f[Statfs.kb_avail]  = (sfs.inner.f_bsize * sfs.inner.f_bavail) / 1024;
    f[Statfs.kb_used]   = sfs.fields[Statfs.kb_total] - sfs.fields[Statfs.kb_avail];
    f[Statfs.ino_total] = sfs.inner.f_files;
    f[Statfs.ino_free]  = sfs.inner.f_ffree;
    f[Statfs.ino_used]  = sfs.inner.f_files - sfs.inner.f_ffree;
    // zig fmt: on

    const fg, const bg = w.check(sfs, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.DiskOpt = @enumFromInt(part.opt);
        const bit = typ.optBit(part.opt);

        if (opt == .arg) {
            uio.writeStr(writer, wd.getMountpoint());
            continue;
        }

        var nu: unt.NumUnit = undefined;
        if (bit & wd.opt_mask.pct != 0) {
            nu = unt.Percent(
                sfs.fields[part.opt],
                sfs.fields[
                    if (bit & wd.opt_mask.pct_ino != 0)
                        Statfs.ino_total
                    else
                        Statfs.kb_total
                ],
            );
        } else if (bit & wd.opt_mask.size != 0) {
            nu = unt.SizeKb(sfs.fields[part.opt - typ.DiskOpt.SIZE_OPTS_OFF]);
        } else {
            nu = unt.UnitSI(sfs.fields[part.opt - typ.DiskOpt.SI_INO_OPTS_OFF]);
        }
        nu.write(writer, part.wopts, part.quiet);
    }
    wd.format.last_str.writeBytes(writer, base);
}
