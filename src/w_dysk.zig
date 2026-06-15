const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const ext = @import("util/ext.zig");
const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");

const Mount = struct {
    fields: [8]u64,

    // zig fmt: off
    const kb_total  = @intFromEnum(typ.Opts.Disk.total);
    const kb_free   = @intFromEnum(typ.Opts.Disk.free);
    const kb_avail  = @intFromEnum(typ.Opts.Disk.available);
    const kb_used   = @intFromEnum(typ.Opts.Disk.used);
    const ino_total = @intFromEnum(typ.Opts.Disk.ino_total);
    const ino_free  = @intFromEnum(typ.Opts.Disk.ino_free);
    const ino_used  = @intFromEnum(typ.Opts.Disk.ino_used);

    comptime {
        std.debug.assert(kb_total  == 0);
        std.debug.assert(kb_free   == 1);
        std.debug.assert(kb_avail  == 2);
        std.debug.assert(kb_used   == 3);
        std.debug.assert(ino_total == 4);
        std.debug.assert(ino_free  == 5);
        std.debug.assert(ino_used  == 6);
    }
    // zig fmt: on

    const zero: Mount = .{ .fields = @splat(0) };
};

const MountPair = struct {
    pair: [2]Mount,
    curr: u8,

    const zero: MountPair = .{ .pair = .{ .zero, .zero }, .curr = 0 };

    pub fn checkPairs(
        self: *const @This(),
        opt: u8,
        pct: bool,
        pairs: []const color.Active.Pair,
    ) color.Hex {
        _ = pct;
        const mount = &self.pair[self.curr];
        const value = unt.Percent(
            mount.fields[opt],
            mount.fields[
                if (typ.optBit(opt) & typ.Opts.Disk.INO_MASK != 0)
                    Mount.ino_total
                else
                    Mount.kb_total
            ],
        ).n.roundU24AndTruncate();
        return color.firstColorGEThreshold(value, pairs);
    }
};

// == public ==================================================================

pub const State = struct {
    mounts: []MountPair,

    pub fn init(reg: *umem.Region, widgets: []const typ.Widget) !@This() {
        const base = reg.head.ptr;

        var id: u8 = 0;
        var mounts: []MountPair = &.{};
        for (widgets) |*w| {
            if (w.id == .DISK) {
                w.getData(.DISK, base).mount_id = id;
                id += 1;
                const ret = try reg.pushVec(&mounts, .front);
                ret.* = .zero;
            }
        }
        return .{ .mounts = mounts };
    }
};

pub fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    parts: []const typ.Format.Part,
    base: [*]const u8,
    state: *const State,
) void {
    const interval = w.readInterval(base);
    const wd = w.getDataConst(.DISK, base);

    var sfs: ext.struct_statfs = undefined;
    while (true) {
        const ret = ext.sys_statfs(wd.getMountpoint(), &sfs);
        if (ret == 0) {
            @branchHint(.likely);
            break;
        }
        if (ret != -ext.c.EINTR) {
            const fg, const bg = w.colorForceStatic();
            typ.writeWidgetBeg(writer, fg, bg);
            uio.writeStr(writer, wd.getMountpoint());
            uio.writeStr(writer, ": ");
            uio.writeStr(writer, switch (ret) {
                -ext.c.EACCES => "<no access>",
                -ext.c.ENOENT, -ext.c.ENOTDIR => "<not mounted>",
                -ext.c.ENOSYS => "<not supported>",
                else => "<unexpected error>",
            });
            return;
        }
    }
    const mount = &state.mounts[wd.mount_id];
    mount.curr ^= 1;
    const curr, const prev = typ.currPrev(Mount, &mount.pair, mount.curr);

    // zig fmt: off
    const f_bsize: c_ulong       = @intCast(sfs.f_bsize);
    curr.fields[Mount.kb_total]  = (f_bsize * sfs.f_blocks) / 1024;
    curr.fields[Mount.kb_free]   = (f_bsize * sfs.f_bfree) / 1024;
    curr.fields[Mount.kb_avail]  = (f_bsize * sfs.f_bavail) / 1024;
    curr.fields[Mount.kb_used]   = curr.fields[Mount.kb_total] - curr.fields[Mount.kb_free];
    curr.fields[Mount.ino_total] = sfs.f_files;
    curr.fields[Mount.ino_free]  = sfs.f_ffree;
    curr.fields[Mount.ino_used]  = sfs.f_files - sfs.f_ffree;
    // zig fmt: on

    const fg, const bg = w.check(mount, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (parts) |*part| {
        part.str.writeBytes(writer, base);

        const bit = typ.optBit(part.opt);

        var negative = false;
        var nu: unt.NumUnit = undefined;

        if (part.flags.pct) {
            nu = unt.Percent(
                curr.fields[part.opt],
                curr.fields[
                    if (bit & typ.Opts.Disk.INO_MASK != 0)
                        Mount.ino_total
                    else
                        Mount.kb_total
                ],
            );
        } else {
            const value, negative = typ.calcWithOverflow(
                curr.fields[part.opt],
                prev.fields[part.opt],
                interval,
                part.flags,
            );
            nu = if (bit & typ.Opts.Disk.INO_MASK != 0)
                unt.UnitSI(value)
            else
                unt.SizeKb(value);
        }
        const wopts = part.wopts.copyAndSetNegative(negative);
        nu.write(writer, wopts);
    }
}
