const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const ext = @import("util/ext.zig");
const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");

const Mount = struct {
    fields: [8]u64,

    const kb_total = 0;
    const kb_free = 1;
    const kb_avail = 2;
    const kb_used = 3;
    const ino_total = 4;
    const ino_free = 5;
    const ino_used = 6;

    comptime {
        const assert = std.debug.assert;
        assert(kb_total == @intFromEnum(typ.Options.Disk.total));
        assert(kb_free == @intFromEnum(typ.Options.Disk.free));
        assert(kb_avail == @intFromEnum(typ.Options.Disk.available));
        assert(kb_used == @intFromEnum(typ.Options.Disk.used));
        assert(ino_total == @intFromEnum(typ.Options.Disk.ino_total));
        assert(ino_free == @intFromEnum(typ.Options.Disk.ino_free));
        assert(ino_used == @intFromEnum(typ.Options.Disk.ino_used));
    }

    const zero: Mount = .{ .fields = @splat(0) };
};

const MountPair = struct {
    pair: [2]Mount,

    curr: u8,
    opt_mask_ino: typ.OptBit,

    fn init(opt_mask_ino: typ.OptBit) @This() {
        return .{
            .pair = .{ .zero, .zero },
            .curr = 0,
            .opt_mask_ino = opt_mask_ino,
        };
    }

    pub fn checkPairs(self: *const @This(), ac: color.Active, base: [*]const u8) color.Hex {
        const mount = &self.pair[self.curr];
        return color.firstColorGEThreshold(
            unt.Percent(
                mount.fields[ac.opt],
                mount.fields[
                    if (typ.optBit(ac.opt) & self.opt_mask_ino != 0)
                        Mount.ino_total
                    else
                        Mount.kb_total
                ],
            ).n.roundU24AndTruncate(),
            ac.pairs.get(base),
        );
    }
};

// == public ==================================================================

pub const State = struct {
    mounts: []MountPair,

    pub fn init(reg: *umem.Region, widgets: []typ.Widget) !@This() {
        var id: u8 = 0;
        var mounts: []MountPair = &.{};
        for (widgets) |*w| {
            if (w.id == .DISK) {
                w.data.DISK.mount_id = id;
                id += 1;
                const ret = try reg.pushVec(&mounts, .front);
                ret.* = .init(w.data.DISK.opt_mask.ino);
            }
        }
        return .{ .mounts = mounts };
    }
};

pub inline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    parts: []const typ.Format.Part,
    base: [*]const u8,
    state: *const State,
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
    const mount = &state.mounts[wd.mount_id];
    mount.curr ^= 1;
    const curr, const prev = typ.currPrev(Mount, &mount.pair, mount.curr);

    // zig fmt: off
    curr.fields[Mount.kb_total]  = (sfs.f_bsize * sfs.f_blocks) / 1024;
    curr.fields[Mount.kb_free]   = (sfs.f_bsize * sfs.f_bfree) / 1024;
    curr.fields[Mount.kb_avail]  = (sfs.f_bsize * sfs.f_bavail) / 1024;
    curr.fields[Mount.kb_used]   = curr.fields[Mount.kb_total] - curr.fields[Mount.kb_free];
    curr.fields[Mount.ino_total] = sfs.f_files;
    curr.fields[Mount.ino_free]  = sfs.f_ffree;
    curr.fields[Mount.ino_used]  = sfs.f_files - sfs.f_ffree;
    // zig fmt: on

    const fg, const bg = w.check(mount, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (parts) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.Options.Disk = @enumFromInt(part.opt);
        const bit = typ.optBit(part.opt);

        if (opt == .arg) {
            uio.writeStr(writer, wd.getMountpoint());
            continue;
        }

        var flags: unt.NumUnit.Flags = .{
            .negative = false,
            .quiet = part.flags.quiet,
            .abbreviate = part.flags.abbreviate,
        };
        var nu: unt.NumUnit = undefined;
        if (part.flags.pct) {
            nu = unt.Percent(
                curr.fields[part.opt],
                curr.fields[
                    if (bit & wd.opt_mask.ino != 0)
                        Mount.ino_total
                    else
                        Mount.kb_total
                ],
            );
        } else {
            const value, flags.negative = typ.calcWithOverflow(
                curr.fields[part.opt],
                prev.fields[part.opt],
                w.interval,
                part.flags,
            );
            nu = if (bit & wd.opt_mask.ino != 0)
                unt.UnitSI(value)
            else
                unt.SizeKb(value);
        }
        nu.write(writer, part.wopts, flags);
    }
}
