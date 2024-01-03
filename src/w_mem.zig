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

    const nread = proc_meminfo.pread(&meminfo_buf, 0) catch |err| {
        utl.fatal(&.{ "MEM: pread: ", @errorName(err) });
    };

    const MEMINFO_KEY_LEN = "xxxxxxxx:       ".len;
    var slots: [5]u64 = undefined;

    var i: usize = MEMINFO_KEY_LEN;
    var nvals: usize = 0;
    var ndigits: usize = 0;
    out: while (i < nread) : (i += 1) switch (meminfo_buf[i]) {
        ' ' => {
            if (ndigits > 0) {
                slots[nvals] = utl.unsafeAtou64(meminfo_buf[i - ndigits .. i]);
                nvals += 1;
                if (nvals == slots.len) break :out;
                ndigits = 0;
                // jump to the next key
                i += "kB\n".len + MEMINFO_KEY_LEN;
            }
        },
        '0'...'9' => ndigits += 1,
        else => {},
    };

    const total_kb = slots[0];
    const free_kb = slots[1];
    const avail_kb = slots[2];
    const buffers_kb = slots[3];
    const cached_kb = slots[4];

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
