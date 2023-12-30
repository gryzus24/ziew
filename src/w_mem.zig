const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
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

const ColorHandler = struct {
    used_kb: u64,
    free_kb: u64,
    avail_kb: u64,
    cached_kb: u64,
    total_kb: u64,

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            switch (@as(typ.MemOpt, @enumFromInt(mc.opt))) {
                .@"%used" => utl.percentOf(self.used_kb, self.total_kb),
                .@"%free" => utl.percentOf(self.free_kb, self.total_kb),
                .@"%available" => utl.percentOf(self.avail_kb, self.total_kb),
                .@"%cached" => utl.percentOf(self.cached_kb, self.total_kb),
                .used, .total, .free, .available, .buffers, .cached => unreachable,
            }.val,
            mc.colors,
        );
    }
};

pub fn widget(
    stream: anytype,
    proc_meminfo: *const fs.File,
    cf: *const cfg.ConfigFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
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

    const writer = stream.writer();
    const ch = ColorHandler{
        .used_kb = used_kb,
        .free_kb = free_kb,
        .avail_kb = avail_kb,
        .cached_kb = cached_kb,
        .total_kb = total_kb,
    };

    utl.writeBlockStart(writer, fg.getColor(ch), bg.getColor(ch));
    utl.writeStr(writer, cf.parts[0]);
    for (cf.iterOpts(), cf.iterParts()[1..]) |*opt, *part| {
        const nu = switch (@as(typ.MemOpt, @enumFromInt(opt.opt))) {
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

        utl.writeNumUnit(writer, nu, opt.alignment, opt.precision);
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
