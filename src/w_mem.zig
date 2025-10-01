const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;

// == private =================================================================

fn parseProcMeminfo(buf: []const u8, new: *MemState) void {
    const KEY_LEN = "xxxxxxxx:       ".len;
    const VAL_LEN = 8;
    const UNIT_LEN = " kB".len;
    const FIELD_LEN = KEY_LEN + VAL_LEN + UNIT_LEN;

    // This isn't the most optimal arrangement of loops in terms of
    // instructions executed, but it generates nice and small code.
    var i: usize = FIELD_LEN;
    for (0..7) |fi| {
        while (buf[i] != '\n') : (i += 1) {}
        // Will break on systems with over 953 GB of RAM.
        new.fields[fi] = utl.atou32V9Back(buf[0 .. i - "kb\n".len]);

        if (fi == 4) {
            // Skipping 11 fields is tight for kernels
            // with HIGHMEM and ZSWAP configured out.
            i += 11 * (FIELD_LEN + 1);
            while (true) {
                while (buf[i] != '\n') : (i += 1) {}
                if (buf[i + 1] == 'D') break;
                i += FIELD_LEN + 1;
            }
        }
        i += FIELD_LEN + 1;
    }
}

test "/proc/meminfo parser" {
    const t = std.testing;

    const buf =
        \\MemTotal:       163245324 kB
        \\MemFree:         6628464 kB
        \\MemAvailable:   106210048 kB
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
        \\SReclaimable:      22222 kB
        \\SUnreclaim:        33333 kB
        \\KernelStack:       11184 kB
        \\PageTables:        17444 kB
        \\SecPageTables:      2056 kB
    ;
    var s: MemState = .init();
    parseProcMeminfo(buf, &s);
    try t.expect(s.total() == 163245324);
    try t.expect(s.free() == 6628464);
    try t.expect(s.avail() == 106210048);
    try t.expect(s.buffers() == 234640);
    try t.expect(s.cached() == 3970504);
    try t.expect(s.dirty() == 28);
    try t.expect(s.writeback() == 0);
}

// == public ==================================================================

pub const MemState = struct {
    fields: [7]u64 = @splat(0),
    proc_meminfo: fs.File,

    pub fn init() MemState {
        return .{
            .proc_meminfo = fs.cwd().openFileZ("/proc/meminfo", .{}) catch |e| {
                log.fatal(&.{ "open: /proc/meminfo: ", @errorName(e) });
            },
        };
    }

    pub fn checkPairs(self: @This(), ac: color.Active, base: [*]const u8) color.Hex {
        return color.firstColorGEThreshold(
            unt.Percent(
                switch (@as(typ.MemOpt.ColorSupported, @enumFromInt(ac.opt))) {
                    .@"%free" => self.free(),
                    .@"%available" => self.avail(),
                    .@"%buffers" => self.buffers(),
                    .@"%cached" => self.cached(),
                    .@"%used" => self.used(),
                },
                self.total(),
            ).n.roundU24AndTruncate(),
            ac.pairs.get(base),
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
    const nr_read = state.proc_meminfo.pread(&buf, 0) catch |e| {
        log.fatal(&.{ "MEM: pread: ", @errorName(e) });
    };
    if (nr_read == buf.len)
        log.fatal(&.{"MEM: /proc/meminfo doesn't fit in 1 page"});

    parseProcMeminfo(&buf, state);
}

pub noinline fn widget(
    writer: *io.Writer,
    w: *const typ.Widget,
    base: [*]const u8,
    state: *const MemState,
) void {
    const wd = w.wid.MEM;

    const fg, const bg = w.check(state, base);
    utl.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);
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
        nu.write(writer, part.wopts, part.quiet);
    }
    wd.format.last_str.writeBytes(writer, base);
}
