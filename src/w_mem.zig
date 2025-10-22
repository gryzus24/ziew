const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");
const ustr = @import("util/str.zig");

const linux = std.os.linux;

// == private =================================================================

fn parseProcMeminfo(buf: []const u8, out: *State) void {
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
        out.fields[fi] = ustr.atou32V9Back(buf[0 .. i - "kb\n".len]);

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
    out.fields[7] = out.total() - out.avail();
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
    var s: State = .init();
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

pub const State = struct {
    fields: [NR_FIELDS]u64,
    fd: linux.fd_t,

    const NR_FIELDS = 8;
    comptime {
        const nr_pct = @typeInfo(typ.MemOpt.PercentOpts).@"enum".fields.len;
        const nr_size = @typeInfo(typ.MemOpt.SizeOpts).@"enum".fields.len;
        std.debug.assert(nr_pct == NR_FIELDS and NR_FIELDS == nr_size);
    }

    pub fn init() State {
        return .{
            .fields = @splat(0),
            .fd = uio.open0("/proc/meminfo") catch |e|
                log.fatal(&.{ "open: /proc/meminfo: ", @errorName(e) }),
        };
    }

    pub fn checkPairs(self: *const @This(), ac: color.Active, base: [*]const u8) color.Hex {
        return color.firstColorGEThreshold(
            unt.Percent(
                self.fields[ac.opt],
                self.total(),
            ).n.roundU24AndTruncate(),
            ac.pairs.get(base),
        );
    }

    // zig fmt: off
    fn     total(self: @This()) u64 { return self.fields[0]; }
    fn      free(self: @This()) u64 { return self.fields[1]; }
    fn     avail(self: @This()) u64 { return self.fields[2]; }
    fn   buffers(self: @This()) u64 { return self.fields[3]; }
    fn    cached(self: @This()) u64 { return self.fields[4]; }
    fn     dirty(self: @This()) u64 { return self.fields[5]; }
    fn writeback(self: @This()) u64 { return self.fields[6]; }
    fn      used(self: @This()) u64 { return self.fields[7]; }
    // zig fmt: on
};

pub inline fn update(state: *State) error{ReadError}!void {
    var buf: [8192]u8 = undefined;
    const n = try uio.pread(state.fd, &buf, 0);
    parseProcMeminfo(buf[0..n], state);
}

pub inline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    base: [*]const u8,
    state: *const State,
) void {
    const wd = w.data.MEM;

    const fg, const bg = w.check(state, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (w.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        var nu: unt.NumUnit = undefined;
        if (typ.optBit(part.opt) & wd.opt_mask.pct != 0) {
            nu = unt.Percent(
                state.fields[part.opt],
                state.total(),
            );
        } else {
            nu = unt.SizeKb(state.fields[part.opt - typ.MemOpt.SIZE_OPTS_OFF]);
        }
        const flags: unt.NumUnit.Flags = .{
            .quiet = part.flags.quiet,
            .negative = false,
        };
        nu.write(writer, part.wopts, flags);
    }
}
