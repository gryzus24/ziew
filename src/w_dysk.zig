const std = @import("std");
const cfg = @import("config.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;

fn checkManyColors(
    used_kb: u64,
    free_kb: u64,
    avail_kb: u64,
    total_kb: u64,
    mc: cfg.ManyColors,
) ?*const [7]u8 {
    return utl.checkColor(
        switch (@as(typ.DiskOpt, @enumFromInt(mc.opt))) {
            .@"%used" => utl.percentOf(used_kb, total_kb),
            .@"%free" => utl.percentOf(free_kb, total_kb),
            .@"%available" => utl.percentOf(avail_kb, total_kb),
            .used, .total, .free, .available, .@"-" => unreachable,
        }.val,
        mc.colors,
    );
}

// takes in one required argument in cf.parts[0]: <mountpoint>
pub fn widget(
    stream: anytype,
    cf: *const cfg.ConfigFormat,
    fg: *const cfg.ColorUnion,
    bg: *const cfg.ColorUnion,
) []const u8 {
    var buf: [typ.WIDGET_BUF_BYTES_MAX / 2]u8 = undefined;

    const mountpoint: [:0]u8 = blk: {
        const arg = cf.parts[0];
        if (arg.len >= buf.len)
            utl.fatal("DISK: mountpoint too scary", .{});
        @memcpy(buf[0..arg.len], arg);
        buf[arg.len] = '\x00';
        break :blk buf[0..arg.len :0];
    };

    // TODO: use statvfs instead of this
    var res: c.struct_statfs = undefined;
    const ret = c.statfs(mountpoint, &res);
    if (ret != 0)
        utl.fatal("DISK: bad mountpoint '{s}'", .{mountpoint});

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

    const fg_hex = switch (fg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkManyColors(used_kb, free_kb, avail_kb, total_kb, t),
    };
    const bg_hex = switch (bg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkManyColors(used_kb, free_kb, avail_kb, total_kb, t),
    };

    const writer = stream.writer();

    utl.writeBlockStart(writer, fg_hex, bg_hex);
    utl.writeStr(writer, cf.parts[1]);
    for (1..cf.nparts - 1) |i| {
        var value_type: utl.AlignmentValueType = .size;

        const nu = switch (@as(typ.DiskOpt, @enumFromInt(cf.opts[i]))) {
            .@"%used" => blk: {
                value_type = .percent;
                break :blk utl.percentOf(used_kb, total_kb);
            },
            .@"%free" => blk: {
                value_type = .percent;
                break :blk utl.percentOf(free_kb, total_kb);
            },
            .@"%available" => blk: {
                value_type = .percent;
                break :blk utl.percentOf(avail_kb, total_kb);
            },
            .used => utl.kbToHuman(used_kb),
            .total => utl.kbToHuman(total_kb),
            .free => utl.kbToHuman(free_kb),
            .available => utl.kbToHuman(avail_kb),
            .@"-" => unreachable,
        };

        const prec = cf.opts_precision[i];
        const ali = cf.opts_alignment[i];

        if (ali == .right)
            utl.writeAlignment(writer, value_type, nu.val, prec);

        if (prec == 0) {
            utl.writeInt(writer, @intFromFloat(@round(nu.val)));
        } else {
            utl.writeFloat(writer, nu.val, prec);
        }
        utl.writeStr(writer, &[1]u8{nu.unit});

        if (ali == .left)
            utl.writeAlignment(writer, value_type, nu.val, prec);

        utl.writeStr(writer, cf.parts[1 + i]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
