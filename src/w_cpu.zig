const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const misc = @import("util/misc.zig");
const udiv = @import("util/div.zig");
const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");
const ustr = @import("util/str.zig");

const linux = std.os.linux;

const DELTA_ZERO_CHECK = false;

const Cpu = struct {
    user: u64,
    sys: u64,
    idle: u64,
    iowait: u64,

    pub const zero: Cpu = .{ .user = 0, .sys = 0, .idle = 0, .iowait = 0 };

    const Delta = struct {
        all: unt.F5608,
        user: unt.F5608,
        sys: unt.F5608,
        iowait: unt.F5608,

        pub const zero: Delta = .{
            .all = .init(0),
            .user = .init(0),
            .sys = .init(0),
            .iowait = .init(0),
        };
    };

    inline fn __delta(self: Cpu, old: Cpu, nr_cpus: u32) Delta {
        const V = @Vector(4, u64);
        const a: V = .{ self.user, self.sys, self.idle, self.iowait };
        const b: V = .{ old.user, old.sys, old.idle, old.iowait };
        const diff = a - b;
        const diff_total = diff[0] + diff[1] + diff[2] + diff[3];

        if (DELTA_ZERO_CHECK and diff_total == 0)
            return .zero;

        // Doing vector multiplication isn't worth it as some
        // callers are interested only in the `.all` value.
        const u = diff[0] * (100 << unt.F5608.FRAC_SHIFT) * nr_cpus;
        const s = diff[1] * (100 << unt.F5608.FRAC_SHIFT) * nr_cpus;
        const w = diff[3] * (100 << unt.F5608.FRAC_SHIFT) * nr_cpus;

        // zig fmt: off
        return .{
            .all    = .{ .u = (u + s) / diff_total },
            .user   = .{ .u = u / diff_total },
            .sys    = .{ .u = s / diff_total },
            .iowait = .{ .u = w / diff_total },
        };
        // zig fmt: on
    }

    pub inline fn delta(self: Cpu, old: Cpu) Delta {
        return self.__delta(old, 1);
    }

    pub inline fn deltaN(self: Cpu, old: Cpu, nr_cpus: u32) Delta {
        return self.__delta(old, nr_cpus);
    }
};

const Stat = struct {
    entries: [*]Cpu,
    nr_cpux_entries: usize,
    stats: [6]u64,

    const intr = 0;
    const softirq = 1;
    const blocked = 2;
    const running = 3;
    const forks = 4;
    const ctxt = 5;

    comptime {
        const assert = std.debug.assert;
        const off = typ.Options.Cpu.STATS_OFF;
        assert(intr == @intFromEnum(typ.Options.Cpu.intr) - off);
        assert(softirq == @intFromEnum(typ.Options.Cpu.softirq) - off);
        assert(blocked == @intFromEnum(typ.Options.Cpu.blocked) - off);
        assert(running == @intFromEnum(typ.Options.Cpu.running) - off);
        assert(forks == @intFromEnum(typ.Options.Cpu.forks) - off);
        assert(ctxt == @intFromEnum(typ.Options.Cpu.ctxt) - off);
    }

    fn initZero(reg: *umem.Region, nr_possible_cpus: u32) !@This() {
        // First entry is the cumulative stat of every CPU.
        const entries = try reg.allocMany(Cpu, nr_possible_cpus + 1, .front);
        for (0..entries.len) |i| entries[i] = .zero;
        return .{
            .entries = entries.ptr,
            .nr_cpux_entries = 0,
            .stats = @splat(0),
        };
    }
};

// == private =================================================================

inline fn parseProcStat(buf: []const u8, out: *Stat) void {
    var cpu: usize = 0;
    var i = "cpu  ".len;
    while (true) {
        var fields: [8]u64 = undefined;
        for (0..fields.len) |fi| {
            fields[fi], i = ustr.atou64By8ForwardUntil(buf, i, ' ');
            i += 1;
        }
        const ptr = &out.entries[cpu];
        // zig fmt: off
        // User time includes guest time. Check v6.17 kernel/sched/cputime.c#L158
        //           user        nice
        //           system      irq         softirq     steal
        ptr.user   = fields[0] + fields[1];
        ptr.sys    = fields[2] + fields[5] + fields[6] + fields[7];
        ptr.idle   = fields[3];
        ptr.iowait = fields[4];
        // zig fmt: on

        // cpuXX  41208 ... 1061 0 [0] 0\n
        i += "0 0\n".len;
        // cpuXX  41208 ... 1061 0 0 0\n[c] (best case)
        while (buf[i] <= '9') : (i += 1) {}
        if (buf[i] == 'i') break;

        i += "cpuX".len;
        while (buf[i] != ' ') : (i += 1) {}
        i += 1;
        cpu += 1;
    }
    // Value of `Stat.nr_cpux_entries` may change - CPUs might go online/offline.
    out.nr_cpux_entries = cpu;

    i += "intr ".len;
    out.stats[Stat.intr], _ = ustr.atou64ForwardUntil(buf, i, ' ');

    const Block = @Vector(32, u8);

    // We have some numbers to skip, use this opportunity to align the pointer
    // and make sure we don't catch the $'\n' at `buf[buf.len - 1]`.
    i = (buf.len - 1) & ~@as(usize, 31);
    while (true) : (i -= 32) {
        const block: Block = buf[i - 32 ..][0..32].*;
        const mask: u32 = @bitCast(block == @as(Block, @splat('\n')));
        if (mask != 0) {
            i -= @clz(mask);
            i += "softirq ".len;
            break;
        }
    }
    out.stats[Stat.softirq], _ = ustr.atou64ForwardUntil(buf, i, ' ');
    i -= "\nsoftirq X".len;

    out.stats[Stat.blocked], i = ustr.atou64BackwardUntil(buf, i, ' ');
    i -= "\nprocs_blocked ".len;

    out.stats[Stat.running], i = ustr.atou64BackwardUntil(buf, i, ' ');
    i -= "\nprocs_running ".len;

    out.stats[Stat.forks], i = ustr.atou64BackwardUntil(buf, i, ' ');
    i -= "\nprocesses ".len;
    const block: Block = buf[i - 32 ..][0..32].*;
    const mask: u32 = @bitCast(block == @as(Block, @splat('\n')));
    i -= @clz(mask);
    i -= 2;

    out.stats[Stat.ctxt], _ = ustr.atou64BackwardUntil(buf, i, ' ');
}

test "/proc/stat parser" {
    const t = std.testing;

    const s =
        \\cpu  46232 14 14383 12181824987654321 2122 2994 1212 0 0 0
        \\cpu0 9483 5 1638 1007864 211 917 227 0 0 0
        \\cpu1 9934 0 1386 1008813 285 200 103 0 0 0
        \\cpu2 10687 4 2756 1006096 257 272 158 0 0 0
        \\cpu3 4310 2 2257 1013687 165 195 103 0 0 0
        \\cpu4 2183 0 1382 1016243 194 205 149 0 0 0
        \\cpu5 1990 0 1088 1016634 167 550 125 0 0 0
        \\cpu6 3005 0 1043 1016226 149 135 80123456 0 0 0
        \\cpu7 1491 0 811 1018026 141 235 67 0 0 0
        \\cpu8 848 0 573 1019392 150 78 29 0 0 0
        \\cpu9 749 0 378 1019750 122 47 24 0 0 0
        \\cpu10 690 0 295 1019943 136 37 19 0 0 0
        \\cpu11 858 0 769 1019145 138 119 123 0 0 0
        \\intr 1894596 0 33004 0 0 0 0 0 0 0 8008 0 0 182 0 0 0 0 0 0 0 0 0 0 0
        \\ctxt 3055158
        \\btime 17137
        \\processes 8594
        \\procs_running 1
        \\procs_blocked 0
        \\softirq 4426117 14101 3005 4 13791 895 0 4659 16049 6 4977
        \\
    ;
    var tmem: [4096]u8 align(32) = undefined;
    var reg: umem.Region = .init(&tmem, "cputest");

    const buf = try reg.allocMany(u8, s.len, .front);
    @memcpy(buf, s);
    var stat: Stat = try .initZero(&reg, 12);
    parseProcStat(buf, &stat);
    try t.expect(stat.entries[0].user == 46232 + 14);
    try t.expect(stat.entries[0].sys == 14383 + 2994 + 1212 + 0);
    try t.expect(stat.entries[0].idle == 12181824987654321);
    try t.expect(stat.entries[0].iowait == 2122);
    try t.expect(stat.entries[1].user == 9483 + 5);
    try t.expect(stat.entries[1].sys == 1638 + 917 + 227 + 0);
    try t.expect(stat.entries[7].sys == 1043 + 135 + 80123456);
    try t.expect(stat.entries[12].user == 858 + 0);
    try t.expect(stat.entries[12].sys == 769 + 119 + 123 + 0);
    try t.expect(stat.entries[12].idle == 1019145);
    try t.expect(stat.entries[12].iowait == 138);
    try t.expect(stat.stats[Stat.intr] == 1894596);
    try t.expect(stat.stats[Stat.ctxt] == 3055158);
    try t.expect(stat.stats[Stat.forks] == 8594);
    try t.expect(stat.stats[Stat.running] == 1);
    try t.expect(stat.stats[Stat.blocked] == 0);
    try t.expect(stat.stats[Stat.softirq] == 4426117);
}

const BRLBARS: [5][5][3]u8 = .{
    .{ "⠀".*, "⢀".*, "⢠".*, "⢰".*, "⢸".* },
    .{ "⡀".*, "⣀".*, "⣠".*, "⣰".*, "⣸".* },
    .{ "⡄".*, "⣄".*, "⣤".*, "⣴".*, "⣼".* },
    .{ "⡆".*, "⣆".*, "⣦".*, "⣶".*, "⣾".* },
    .{ "⡇".*, "⣇".*, "⣧".*, "⣷".*, "⣿".* },
};

const BLKBARS: [9][3]u8 = .{
    "⠀".*, "▁".*, "▂".*, "▃".*, "▄".*, "▅".*, "▆".*, "▇".*, "█".*,
};

inline fn barIntensity(curr: Cpu, prev: Cpu, comptime range: comptime_int) u32 {
    if (range <= 1) @compileError("range <= 1");
    const step = comptime unt.F5608.init(100).div(range - 1).u;
    const off = step - 1;
    const u_max = (range - 1) * step;

    const pct = curr.delta(prev).all;
    const u = @min(pct.u, u_max);
    const q, _ = udiv.cMultShiftDivMod(u + off, step, u_max + off);
    return @intCast(q);
}

// == public ==================================================================

pub const State = struct {
    stats: [2]Stat,
    usage_pct: [NR_USAGE_FIELDS]unt.F5608,
    usage_abs: [NR_USAGE_FIELDS]unt.F5608,

    curr: u32,
    fd: linux.fd_t,

    const NR_USAGE_FIELDS = @typeInfo(typ.Options.Cpu.Usage).@"enum".fields.len;

    comptime {
        std.debug.assert(NR_USAGE_FIELDS == 4);
    }

    pub fn init(reg: *umem.Region) !State {
        const nr_cpus = misc.nrPossibleCpus();
        const a: Stat = try .initZero(reg, nr_cpus);
        const b: Stat = try .initZero(reg, nr_cpus);
        return .{
            .stats = .{ a, b },
            .usage_pct = @splat(.init(0)),
            .usage_abs = @splat(.init(0)),
            .curr = 0,
            .fd = uio.open0("/proc/stat") catch |e|
                log.fatal(&.{ "open: /proc/stat: ", @errorName(e) }),
        };
    }

    pub fn checkPairs(self: *const @This(), ac: color.Active, base: [*]const u8) color.Hex {
        const curr, const prev = typ.constCurrPrev(Stat, &self.stats, self.curr);
        return color.firstColorGEThreshold(
            switch (@as(typ.Options.Cpu.ColorAdjacent, @enumFromInt(ac.opt))) {
                .all,
                .user,
                .sys,
                .iowait,
                => self.usage_pct[ac.opt].roundU24AndTruncate(),
                .blocked => curr.stats[Stat.blocked],
                .running => curr.stats[Stat.running],
                .forks => curr.stats[Stat.forks] - prev.stats[Stat.forks],
            },
            ac.pairs.get(base),
        );
    }
};

pub inline fn update(state: *State) error{ReadError}!void {
    var buf: [8192]u8 = undefined;
    const n = try uio.pread(state.fd, &buf, 0);
    if (n == buf.len) log.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    state.curr ^= 1;
    const curr, const prev = typ.currPrev(Stat, &state.stats, state.curr);

    parseProcStat(buf[0..n], curr);

    const curr_cpu = curr.entries[0];
    const prev_cpu = prev.entries[0];
    const delta = curr_cpu.delta(prev_cpu);
    const deltaN = curr_cpu.deltaN(prev_cpu, @intCast(curr.nr_cpux_entries));

    // zig fmt: off
    state.usage_pct[@intFromEnum(typ.Options.Cpu.all)]    = delta.all;
    state.usage_pct[@intFromEnum(typ.Options.Cpu.user)]   = delta.user;
    state.usage_pct[@intFromEnum(typ.Options.Cpu.sys)]    = delta.sys;
    state.usage_pct[@intFromEnum(typ.Options.Cpu.iowait)] = delta.iowait;

    state.usage_abs[@intFromEnum(typ.Options.Cpu.all)]    = deltaN.all;
    state.usage_abs[@intFromEnum(typ.Options.Cpu.user)]   = deltaN.user;
    state.usage_abs[@intFromEnum(typ.Options.Cpu.sys)]    = deltaN.sys;
    state.usage_abs[@intFromEnum(typ.Options.Cpu.iowait)] = deltaN.iowait;
    // zig fmt: on
}

pub inline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    parts: []const typ.Format.Part,
    base: [*]const u8,
    state: *const State,
) void {
    const wd = w.data.CPU;
    const curr, const prev = typ.constCurrPrev(Stat, &state.stats, state.curr);

    const fg, const bg = w.check(state, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (parts) |*part| {
        part.str.writeBytes(writer, base);

        const bit = typ.optBit(part.opt);
        if (bit & (wd.opt_mask.usage | wd.opt_mask.stats) != 0) {
            var negative = false;
            var nu: unt.NumUnit = undefined;

            if (bit & wd.opt_mask.usage != 0) {
                nu = .{
                    .n = if (part.flags.pct)
                        state.usage_pct[part.opt]
                    else
                        state.usage_abs[part.opt],
                    .u = .percent,
                };
            } else {
                const value, negative = typ.calcWithOverflow(
                    curr.stats[part.opt - typ.Options.Cpu.STATS_OFF],
                    prev.stats[part.opt - typ.Options.Cpu.STATS_OFF],
                    w.interval,
                    part.flags,
                );
                nu = unt.UnitSI(value);
            }
            const wopts = part.wopts.copyAndSetNegative(negative);
            nu.write(writer, wopts);
            continue;
        }

        const needed = curr.nr_cpux_entries * @max(BRLBARS[0][0].len, BLKBARS[0].len);
        if (writer.unusedCapacityLen() < needed) {
            @branchHint(.unlikely);
            break;
        }

        const buffer = writer.buffer;
        var pos = writer.end;

        switch (@as(typ.Options.Cpu.Special, @enumFromInt(part.opt))) {
            .brlbars => {
                var left: u32 = 0;
                var right: u32 = 0;

                for (1..1 + curr.nr_cpux_entries) |i| {
                    if (i & 1 == 1) {
                        left = barIntensity(curr.entries[i], prev.entries[i], BRLBARS.len);
                    } else {
                        right = barIntensity(curr.entries[i], prev.entries[i], BRLBARS[0].len);
                        buffer[pos..][0..3].* = BRLBARS[left][right];
                        pos += 3;
                    }
                }
                if (curr.nr_cpux_entries & 1 == 1) {
                    buffer[pos..][0..3].* = BRLBARS[left][0];
                    pos += 3;
                }
            },
            .blkbars => {
                for (1..1 + curr.nr_cpux_entries) |i| {
                    buffer[pos..][0..3].* =
                        BLKBARS[barIntensity(curr.entries[i], prev.entries[i], BLKBARS.len)];
                    pos += 3;
                }
            },
        }
        writer.end = pos;
    }
}
