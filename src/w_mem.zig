const std = @import("std");
const cfg = @import("config.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;

const MEMINFO_BUF_SIZE = blk: {
    const w =
        \\MemTotal:       18446744073709551616 kB
        \\MemFree:        18446744073709551616 kB
        \\MemAvailable:   18446744073709551616 kB
        \\Buffers:        18446744073709551616 kB
        \\Cached:         18446744073709551616 kB
        \\
    ;
    if (w.len != 200) unreachable;
    break :blk w.len;
};

fn parseMemInfoLine(line: []const u8) u64 {
    const value_str = blk: {
        // NOTE: kB is hardcoded in the kernel
        const end = if (line[line.len - 1] == 'B') line.len - 3 else line.len;
        const start = mem.lastIndexOfScalar(u8, line[0..end], ' ').? + 1;
        break :blk line[start..end];
    };
    return fmt.parseUnsigned(u64, value_str, 10) catch unreachable;
}

fn checkManyColors(
    used_kb: u64,
    free_kb: u64,
    avail_kb: u64,
    cached_kb: u64,
    total_kb: u64,
    mc: cfg.ManyColors,
) ?*const [7]u8 {
    return utl.checkColorAboveThreshold(
        switch (@as(typ.MemOpt, @enumFromInt(mc.opt))) {
            .@"%used" => utl.percentOf(used_kb, total_kb),
            .@"%free" => utl.percentOf(free_kb, total_kb),
            .@"%available" => utl.percentOf(avail_kb, total_kb),
            .@"%cached" => utl.percentOf(cached_kb, total_kb),
            .used, .total, .free, .available, .buffers, .cached => unreachable,
        }.val,
        mc.colors,
    );
}

pub fn widget(
    stream: anytype,
    proc_meminfo: *const fs.File,
    cf: *const cfg.ConfigFormat,
    fg: *const cfg.ColorUnion,
    bg: *const cfg.ColorUnion,
) []const u8 {
    var meminfo_buf: [MEMINFO_BUF_SIZE]u8 = undefined;

    _ = proc_meminfo.pread(&meminfo_buf, 0) catch |err| {
        utl.fatal("MEM: pread: {}", .{err});
    };

    var pos: usize = 0;
    var end: usize = 0;

    end = mem.indexOfScalar(u8, meminfo_buf[pos..], '\n').?;
    const total_kb = parseMemInfoLine(meminfo_buf[pos..end]);
    pos = end + 1;

    end = pos + mem.indexOfScalar(u8, meminfo_buf[pos..], '\n').?;
    const free_kb = parseMemInfoLine(meminfo_buf[pos..end]);
    pos = end + 1;

    end = pos + mem.indexOfScalar(u8, meminfo_buf[pos..], '\n').?;
    const avail_kb = parseMemInfoLine(meminfo_buf[pos..end]);
    pos = end + 1;

    end = pos + mem.indexOfScalar(u8, meminfo_buf[pos..], '\n').?;
    const buffers_kb = parseMemInfoLine(meminfo_buf[pos..end]);
    pos = end + 1;

    end = pos + mem.indexOfScalar(u8, meminfo_buf[pos..], '\n').?;
    const cached_kb = parseMemInfoLine(meminfo_buf[pos..end]);

    const used_kb = total_kb - avail_kb;

    const fg_hex = switch (fg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkManyColors(used_kb, free_kb, avail_kb, cached_kb, total_kb, t),
    };
    const bg_hex = switch (bg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkManyColors(used_kb, free_kb, avail_kb, cached_kb, total_kb, t),
    };

    const writer = stream.writer();

    utl.writeBlockStart(writer, fg_hex, bg_hex);
    utl.writeStr(writer, cf.parts[0]);
    for (0..cf.nparts - 1) |i| {
        const nu = switch (@as(typ.MemOpt, @enumFromInt(cf.opts[i]))) {
            .@"%used" => utl.percentOf(used_kb, total_kb),
            .@"%free" => utl.percentOf(free_kb, total_kb),
            .@"%available" => utl.percentOf(avail_kb, total_kb),
            .@"%cached" => utl.percentOf(cached_kb, total_kb),
            .used => utl.kbToHuman(used_kb),
            .total => utl.kbToHuman(total_kb),
            .free => utl.kbToHuman(free_kb),
            .available => utl.kbToHuman(avail_kb),
            .buffers => utl.kbToHuman(buffers_kb),
            .cached => utl.kbToHuman(cached_kb),
        };

        utl.writeNumUnit(writer, nu, cf.opts_alignment[i], cf.opts_precision[i]);
        utl.writeStr(writer, cf.parts[1 + i]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
