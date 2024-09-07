const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;

// == private =================================================================

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
    var s: MemState = MemState.init();
    parseProcMeminfo(buf, &s);
    try t.expect(s.total() == 16324532);
    try t.expect(s.free() == 6628464);
    try t.expect(s.avail() == 10621004);
    try t.expect(s.buffers() == 234640);
    try t.expect(s.cached() == 3970504);
    try t.expect(s.dirty() == 28);
    try t.expect(s.writeback() == 0);
}

// == public ==================================================================

pub const WidgetData = struct {
    format: typ.Format = .{},
    fg: typ.Color = .nocolor,
    bg: typ.Color = .nocolor,
};

pub const MemState = struct {
    fields: [7]u64 = .{0} ** 7,
    proc_meminfo: fs.File,

    pub fn init() MemState {
        return .{
            .proc_meminfo = fs.cwd().openFileZ("/proc/meminfo", .{}) catch |e| {
                utl.fatal(&.{ "open: /proc/meminfo: ", @errorName(e) });
            },
        };
    }

    pub fn checkOptColors(self: @This(), oc: typ.OptColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            unt.Percent(
                switch (@as(typ.MemOpt.ColorSupported, @enumFromInt(oc.opt))) {
                    .@"%free" => self.free(),
                    .@"%available" => self.avail(),
                    .@"%buffers" => self.buffers(),
                    .@"%cached" => self.cached(),
                    .@"%used" => self.used(),
                },
                self.total(),
            ).n.roundAndTruncate(),
            oc.colors,
        );
    }

    fn total(self: @This()) u64 {
        return self.fields[0];
    }
    fn free(self: @This()) u64 {
        return self.fields[1];
    }
    fn avail(self: @This()) u64 {
        return self.fields[2];
    }
    fn buffers(self: @This()) u64 {
        return self.fields[3];
    }
    fn cached(self: @This()) u64 {
        return self.fields[4];
    }
    fn dirty(self: @This()) u64 {
        return self.fields[5];
    }
    fn writeback(self: @This()) u64 {
        return self.fields[6];
    }
    fn used(self: @This()) u64 {
        return self.total() - self.avail();
    }
};

pub fn update(state: *MemState) void {
    var buf: [4096]u8 = undefined;
    const nread = state.proc_meminfo.pread(&buf, 0) catch |e| {
        utl.fatal(&.{ "MEM: pread: ", @errorName(e) });
    };
    if (nread == buf.len)
        utl.fatal(&.{"MEM: /proc/meminfo doesn't fit in 1 page"});

    parseProcMeminfo(&buf, state);
}

pub fn widget(
    stream: anytype,
    state: *const MemState,
    w: *const typ.Widget,
) []const u8 {
    const wd = w.wid.MEM;
    const writer = stream.writer();

    utl.writeBlockStart(writer, wd.fg.getColor(state), wd.bg.getColor(state));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(writer, part.part);
        const nu = switch (@as(typ.MemOpt, @enumFromInt(part.opt))) {
            // zig fmt: off
            .@"%free"      => unt.Percent(state.free(), state.total()),
            .@"%available" => unt.Percent(state.avail(), state.total()),
            .@"%cached"    => unt.Percent(state.cached(), state.total()),
            .@"%buffers"   => unt.Percent(state.buffers(), state.total()),
            .@"%used"      => unt.Percent(state.used(), state.total()),
            .total         => unt.SizeKb(state.total()),
            .free          => unt.SizeKb(state.free()),
            .available     => unt.SizeKb(state.avail()),
            .buffers       => unt.SizeKb(state.buffers()),
            .cached        => unt.SizeKb(state.cached()),
            .used          => unt.SizeKb(state.used()),
            .dirty         => unt.SizeKb(state.dirty()),
            .writeback     => unt.SizeKb(state.writeback()),
            // zig fmt: on
        };
        nu.write(writer, part.wopts);
    }
    utl.writeStr(writer, wd.format.part_last);
    return utl.writeBlockEnd_GetWritten(stream);
}
