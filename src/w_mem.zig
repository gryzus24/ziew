const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;

pub const MemState = struct {
    fields: [7]u64 = .{0} ** 7,

    pub fn total(self: @This()) u64 {
        return self.fields[0];
    }
    pub fn free(self: @This()) u64 {
        return self.fields[1];
    }
    pub fn avail(self: @This()) u64 {
        return self.fields[2];
    }
    pub fn buffers(self: @This()) u64 {
        return self.fields[3];
    }
    pub fn cached(self: @This()) u64 {
        return self.fields[4];
    }
    pub fn dirty(self: @This()) u64 {
        return self.fields[5];
    }
    pub fn writeback(self: @This()) u64 {
        return self.fields[6];
    }
    pub fn used(self: @This()) u64 {
        return self.total() - self.avail();
    }

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            switch (@as(typ.MemOpt, @enumFromInt(mc.opt))) {
                .@"%used" => utl.Percent(self.used(), self.total()),
                .@"%free" => utl.Percent(self.free(), self.total()),
                .@"%available" => utl.Percent(self.avail(), self.total()),
                .@"%cached" => utl.Percent(self.cached(), self.total()),
                .used => unreachable,
                .total => unreachable,
                .free => unreachable,
                .available => unreachable,
                .buffers => unreachable,
                .cached => unreachable,
                .dirty => unreachable,
                .writeback => unreachable,
            }.val.roundAndTruncate(),
            mc.colors,
        );
    }
};

fn parseProcMeminfo(buf: []const u8, new: *MemState) void {
    const MEMINFO_KEY_LEN = "xxxxxxxx:       ".len;

    var i: usize = MEMINFO_KEY_LEN;
    for (0..5) |fieldi| {
        while (buf[i] == ' ') : (i += 1) {}
        new.fields[fieldi] = utl.atou64ForwardUntil(buf, &i, ' ');
        i += " kB\n".len + MEMINFO_KEY_LEN;
    }
    // we can safely skip /9/ fields
    i += "0 kb\n".len + 8 * (MEMINFO_KEY_LEN + "0 kb\n".len);

    // look for Dirty
    while (buf[i] != 'D') : (i += 1) {}
    i += MEMINFO_KEY_LEN;

    for (5..7) |fieldi| {
        while (buf[i] == ' ') : (i += 1) {}
        new.fields[fieldi] = utl.atou64ForwardUntil(buf, &i, ' ');
        i += " kb\n".len + MEMINFO_KEY_LEN;
    }
}

pub fn update(meminfo: *const fs.File, state: *MemState) void {
    var buf: [4096]u8 = undefined;
    const nread = meminfo.pread(&buf, 0) catch |err| {
        utl.fatal(&.{ "MEM: pread: ", @errorName(err) });
    };
    if (nread == buf.len)
        utl.fatal(&.{"MEM: /proc/meminfo doesn't fit in 1 page"});

    parseProcMeminfo(&buf, state);
}

test "/proc/meminfo parser" {
    const t = std.testing;

    const buf =
        \\MemTotal:       16324532 kB
        \\MemFree:         6628464 kB
        \\MemAvailable:   10621004 kB
        \\Buffers:          234640 kB
        \\Cached:          3970504 kB
        \\SwapCached:            0 kB
        \\Active:          5683660 kB
        \\Inactive:        3165560 kB
        \\Active(anon):    4868340 kB
        \\Inactive(anon):        0 kB
        \\Active(file):     815320 kB
        \\Inactive(file):  3165560 kB
        \\Unevictable:         584 kB
        \\Mlocked:             584 kB
        \\SwapTotal:             0 kB
        \\SwapFree:              0 kB
        \\Zswap:                 0 kB
        \\Zswapped:              0 kB
        \\Dirty:                28 kB
        \\Writeback:             0 kB
        \\AnonPages:       4639020 kB
        \\Mapped:           714056 kB
        \\Shmem:            224264 kB
        \\KReclaimable:     352524 kB
        \\Slab:             453728 kB
    ;
    var s: MemState = .{};
    parseProcMeminfo(buf, &s);
    try t.expect(s.total() == 16324532);
    try t.expect(s.free() == 6628464);
    try t.expect(s.avail() == 10621004);
    try t.expect(s.buffers() == 234640);
    try t.expect(s.cached() == 3970504);
    try t.expect(s.dirty() == 28);
    try t.expect(s.writeback() == 0);
}

pub fn widget(
    stream: anytype,
    state: *const MemState,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    const writer = stream.writer();

    utl.writeBlockStart(writer, fg.getColor(state), bg.getColor(state));
    utl.writeStr(writer, wf.parts[0]);
    for (wf.iterOpts(), wf.iterParts()[1..]) |*opt, *part| {
        const nu = switch (@as(typ.MemOpt, @enumFromInt(opt.opt))) {
            .@"%used" => utl.Percent(state.used(), state.total()),
            .@"%free" => utl.Percent(state.free(), state.total()),
            .@"%available" => utl.Percent(state.avail(), state.total()),
            .@"%cached" => utl.Percent(state.cached(), state.total()),
            .used => utl.SizeKb(state.used()),
            .total => utl.SizeKb(state.total()),
            .free => utl.SizeKb(state.free()),
            .available => utl.SizeKb(state.avail()),
            .buffers => utl.SizeKb(state.buffers()),
            .cached => utl.SizeKb(state.cached()),
            .dirty => utl.SizeKb(state.dirty()),
            .writeback => utl.SizeKb(state.writeback()),
        };
        nu.write(writer, opt.alignment, opt.precision);
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
