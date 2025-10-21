const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const ext = @import("util/ext.zig");
const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");

const Mount = struct {
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

    fn init(opt_mask_pct_ino: typ.OptBit) @This() {
        return .{ .fields = @splat(0), .opt_mask_pct_ino = opt_mask_pct_ino };
    }
};

// == public ==================================================================

pub const State = struct {
    mounts: [*][2]Mount,
    curr: [*]usize,

    handler: ColorHandler,

    fn getCurrPrev(self: *const @This(), mount_id: u8) struct { *Mount, *Mount } {
        const i = self.curr[mount_id];
        return .{
            @constCast(&self.mounts[mount_id][i]),
            @constCast(&self.mounts[mount_id][i ^ 1]),
        };
    }

    fn swapCurrPrev(self: *@This(), mount_id: u8) void {
        self.curr[mount_id] ^= 1;
    }

    pub fn init(reg: *umem.Region, widgets: []typ.Widget) !@This() {
        // Assign mount ids and count widgets.
        var id: u8 = 0;
        for (widgets) |*w| {
            if (w.id == .DISK) {
                w.data.DISK.mount_id = id;
                id += 1;
            }
        }
        const curr = try reg.allocMany(usize, id, .front);
        @memset(curr, 0);

        // Only now allocate `Mounts` - so that accesses are mostly continuous.
        var mounts: [][2]Mount = &.{};
        for (widgets) |*w| {
            if (w.id == .DISK) {
                const ret = try reg.pushVec(&mounts, .front);
                ret[0] = .init(w.data.DISK.opt_mask.pct_ino);
                ret[1] = .init(w.data.DISK.opt_mask.pct_ino);
            }
        }
        return .{
            .mounts = mounts.ptr,
            .curr = curr.ptr,
            .handler = undefined,
        };
    }

    const ColorHandler = struct {
        mount_id: u8 align(8),

        fn init(mount_id: u8) @This() {
            return .{ .mount_id = mount_id };
        }

        pub fn checkPairs(
            self: *const @This(),
            ac: color.Active,
            base: [*]const u8,
        ) color.Hex {
            const state: *const State = @fieldParentPtr("handler", self);
            const new, _ = state.getCurrPrev(self.mount_id);
            return color.firstColorGEThreshold(
                unt.Percent(
                    new.fields[ac.opt],
                    new.fields[
                        if (typ.optBit(ac.opt) & new.opt_mask_pct_ino != 0)
                            Mount.ino_total
                        else
                            Mount.kb_total
                    ],
                ).n.roundU24AndTruncate(),
                ac.pairs.get(base),
            );
        }
    };
};

pub noinline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    base: [*]const u8,
    state: *State,
) void {
    const wd = w.data.DISK;

    var sfs: ext.struct_statfs = undefined;
    while (true) {
        const ret = ext.sys_statfs(wd.getMountpoint(), &sfs);
        if (ret == 0) {
            @branchHint(.likely);
            break;
        }
        if (ret != -ext.c.EINTR) {
            const handler: typ.Widget.NoopColorHandler = .{};
            const fg, const bg = w.check(handler, base);
            return typ.writeWidget(
                writer,
                fg,
                bg,
                &[3][]const u8{
                    wd.getMountpoint(), ": ", switch (ret) {
                        -ext.c.EACCES => "<no access>",
                        -ext.c.ENOENT, -ext.c.ENOTDIR => "<not mounted>",
                        -ext.c.ENOSYS => "<not supported>",
                        else => "<unexpected error>",
                    },
                },
            );
        }
    }
    state.swapCurrPrev(wd.mount_id);
    var new, const old = state.getCurrPrev(wd.mount_id);

    // zig fmt: off
    const fields = &new.fields;
    fields[Mount.kb_total]  = (sfs.f_bsize * sfs.f_blocks) / 1024;
    fields[Mount.kb_free]   = (sfs.f_bsize * sfs.f_bfree) / 1024;
    fields[Mount.kb_avail]  = (sfs.f_bsize * sfs.f_bavail) / 1024;
    fields[Mount.kb_used]   = fields[Mount.kb_total] - fields[Mount.kb_free];
    fields[Mount.ino_total] = sfs.f_files;
    fields[Mount.ino_free]  = sfs.f_ffree;
    fields[Mount.ino_used]  = sfs.f_files - sfs.f_ffree;
    // zig fmt: on

    state.handler = .init(wd.mount_id);
    const fg, const bg = w.check(&state.handler, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.DiskOpt = @enumFromInt(part.opt);
        const bit = typ.optBit(part.opt);

        if (opt == .arg) {
            uio.writeStr(writer, wd.getMountpoint());
            continue;
        }

        var flags: unt.NumUnit.Flags = .{
            .quiet = part.flags.quiet,
            .negative = false,
        };
        var nu: unt.NumUnit = undefined;
        if (bit & wd.opt_mask.pct != 0) {
            nu = unt.Percent(
                new.fields[part.opt],
                new.fields[
                    if (bit & wd.opt_mask.pct_ino != 0)
                        Mount.ino_total
                    else
                        Mount.kb_total
                ],
            );
        } else if (bit & wd.opt_mask.size != 0) {
            const value, flags.negative = typ.calcWithOverflow(
                new.fields[part.opt - typ.DiskOpt.SIZE_OPTS_OFF],
                old.fields[part.opt - typ.DiskOpt.SIZE_OPTS_OFF],
                w.interval,
                part.flags,
            );
            nu = unt.SizeKb(value);
        } else {
            const value, flags.negative = typ.calcWithOverflow(
                new.fields[part.opt - typ.DiskOpt.SI_INO_OPTS_OFF],
                old.fields[part.opt - typ.DiskOpt.SI_INO_OPTS_OFF],
                w.interval,
                part.flags,
            );
            nu = unt.UnitSI(value);
        }
        nu.write(writer, part.wopts, flags);
    }
    wd.format.last_str.writeBytes(writer, base);
}
