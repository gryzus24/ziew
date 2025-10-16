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
        const off = typ.CpuOpt.STATS_OPTS_OFF;
        assert(intr == @intFromEnum(typ.CpuOpt.intr) - off);
        assert(softirq == @intFromEnum(typ.CpuOpt.softirq) - off);
        assert(blocked == @intFromEnum(typ.CpuOpt.blocked) - off);
        assert(running == @intFromEnum(typ.CpuOpt.running) - off);
        assert(forks == @intFromEnum(typ.CpuOpt.forks) - off);
        assert(ctxt == @intFromEnum(typ.CpuOpt.ctxt) - off);
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

fn parseProcStat(buf: []const u8, out: *Stat) void {
    var cpu: usize = 0;
    var i = "cpu  ".len;
    while (true) {
        var fields: [8]u64 = undefined;
        for (0..fields.len) |fi| {
            fields[fi], i = ustr.atou64ForwardUntil(buf, i, ' ');
            i += 1;
        }
        // zig fmt: off
        // User time includes guest time. Check v6.17 kernel/sched/cputime.c#L158
        //                        user        nice
        //                        system      irq         softirq     steal
        out.entries[cpu].user   = fields[0] + fields[1];
        out.entries[cpu].sys    = fields[2] + fields[5] + fields[6] + fields[7];
        out.entries[cpu].idle   = fields[3];
        out.entries[cpu].iowait = fields[4];
        // zig fmt: on

        // cpuXX  41208 ... 1061 0 [0] 0\n
        i += 4;
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

    i = buf.len - 1 - " 0 0 0 0 0 0 0 0 0 0 0\n".len;
    while (buf[i] != 'q') : (i -= 1) {}
    // i at: softir[q] 123456 2345 ...

    out.stats[Stat.softirq], _ = ustr.atou64ForwardUntil(buf, i + "q ".len, ' ');
    i -= "\nsoftirq".len;

    out.stats[Stat.blocked], i = ustr.atou64BackwardUntil(buf, i, ' ');
    i -= "\nprocs_blocked ".len;

    out.stats[Stat.running], i = ustr.atou64BackwardUntil(buf, i, ' ');
    i -= "\nprocs_running ".len;

    out.stats[Stat.forks], i = ustr.atou64BackwardUntil(buf, i, ' ');
    i -= "btime X\nprocesses ".len;

    while (buf[i] != '\n') : (i -= 1) {}
    out.stats[Stat.ctxt], _ = ustr.atou64BackwardUntil(buf, i - 1, ' ');
}

test "/proc/stat parser" {
    const t = std.testing;

    const buf =
        \\cpu  46232 14 14383 12181824 2122 2994 1212 0 0 0
        \\cpu0 9483 5 1638 1007864 211 917 227 0 0 0
        \\cpu1 9934 0 1386 1008813 285 200 103 0 0 0
        \\cpu2 10687 4 2756 1006096 257 272 158 0 0 0
        \\cpu3 4310 2 2257 1013687 165 195 103 0 0 0
        \\cpu4 2183 0 1382 1016243 194 205 149 0 0 0
        \\cpu5 1990 0 1088 1016634 167 550 125 0 0 0
        \\cpu6 3005 0 1043 1016226 149 135 80 0 0 0
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
        \\softirq 4426117 1410160 300541 4 137919 8958 0 465908 1604918 6 497706
    ;
    var tmem: [4096]u8 align(16) = undefined;
    var reg: umem.Region = .init(&tmem, "cputest");
    var s: Stat = try .initZero(&reg, 12);
    parseProcStat(buf, &s);
    try t.expect(s.entries[0].user == 46232 + 14);
    try t.expect(s.entries[0].sys == 14383 + 2994 + 1212 + 0);
    try t.expect(s.entries[0].idle == 12181824);
    try t.expect(s.entries[0].iowait == 2122);
    try t.expect(s.entries[1].user == 9483 + 5);
    try t.expect(s.entries[1].sys == 1638 + 917 + 227 + 0);
    try t.expect(s.entries[12].user == 858 + 0);
    try t.expect(s.entries[12].sys == 769 + 119 + 123 + 0);
    try t.expect(s.entries[12].idle == 1019145);
    try t.expect(s.entries[12].iowait == 138);
    try t.expect(s.stats[Stat.intr] == 1894596);
    try t.expect(s.stats[Stat.ctxt] == 3055158);
    try t.expect(s.stats[Stat.forks] == 8594);
    try t.expect(s.stats[Stat.running] == 1);
    try t.expect(s.stats[Stat.blocked] == 0);
    try t.expect(s.stats[Stat.softirq] == 4426117);
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

inline fn barIntensity(new: Cpu, old: Cpu, comptime range: comptime_int) u32 {
    if (range <= 1) @compileError("range <= 1");
    const step = comptime unt.F5608.init(100).div(range - 1).u;
    const off = step - 1;
    const u_max = (range - 1) * step;

    const pct = new.delta(old).all;
    const u = @min(pct.u, u_max);
    const q, _ = udiv.cMultShiftDivMod(u + off, step, u_max + off);
    return @intCast(q);
}

// == public ==================================================================

pub const CpuState = struct {
    stats: [2]Stat,
    usage: [NR_USAGE_FIELDS]unt.F5608,

    curr: usize,
    fd: linux.fd_t,

    comptime {
        std.debug.assert(@sizeOf(Stat) == 64);
        std.debug.assert(@sizeOf(@FieldType(CpuState, "usage")) == 64);
    }

    const NR_USAGE_FIELDS = @typeInfo(typ.CpuOpt.UsageOpts).@"enum".fields.len;

    pub fn init(reg: *umem.Region) !CpuState {
        const nr_cpus = misc.nrPossibleCpus();
        const a: Stat = try .initZero(reg, nr_cpus);
        const b: Stat = try .initZero(reg, nr_cpus);
        return .{
            .stats = .{ a, b },
            .usage = @splat(.{ .u = 0 }),
            .curr = 0,
            .fd = uio.open0("/proc/stat") catch |e|
                log.fatal(&.{ "open: /proc/stat: ", @errorName(e) }),
        };
    }

    fn getCurrPrev(self: *const @This()) struct { *Stat, *Stat } {
        const i = self.curr;
        return .{ @constCast(&self.stats[i]), @constCast(&self.stats[i ^ 1]) };
    }

    fn swapCurrPrev(self: *@This()) void {
        self.curr ^= 1;
    }

    pub fn checkPairs(
        self: @This(),
        ac: color.Active,
        base: [*]const u8,
    ) color.Hex {
        const new, const old = self.getCurrPrev();
        return color.firstColorGEThreshold(
            switch (@as(typ.CpuOpt.ColorSupported, @enumFromInt(ac.opt))) {
                .@"%all",
                .@"%user",
                .@"%sys",
                .@"%iowait",
                => self.usage[ac.opt].roundU24AndTruncate(),
                .blocked => new.stats[Stat.blocked],
                .running => new.stats[Stat.running],
                .forks => new.stats[Stat.forks] - old.stats[Stat.forks],
            },
            ac.pairs.get(base),
        );
    }
};

pub fn update(state: *CpuState) error{ReadError}!void {
    var buf: [8192]u8 = undefined;
    const n = try uio.pread(state.fd, &buf, 0);
    if (n == buf.len) log.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    state.swapCurrPrev();
    const new, const old = state.getCurrPrev();

    parseProcStat(buf[0..n], new);

    const new_cpu = new.entries[0];
    const old_cpu = old.entries[0];
    const delta = new_cpu.delta(old_cpu);
    const deltaN = new_cpu.deltaN(old_cpu, @intCast(new.nr_cpux_entries));

    // zig fmt: off
    const u = &state.usage;
    u[@intFromEnum(typ.CpuOpt.@"%all")]    = delta.all;
    u[@intFromEnum(typ.CpuOpt.@"%user")]   = delta.user;
    u[@intFromEnum(typ.CpuOpt.@"%sys")]    = delta.sys;
    u[@intFromEnum(typ.CpuOpt.@"%iowait")] = delta.iowait;
    u[@intFromEnum(typ.CpuOpt.all)]        = deltaN.all;
    u[@intFromEnum(typ.CpuOpt.user)]       = deltaN.user;
    u[@intFromEnum(typ.CpuOpt.sys)]        = deltaN.sys;
    u[@intFromEnum(typ.CpuOpt.iowait)]     = deltaN.iowait;
    // zig fmt: on
}

pub noinline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    base: [*]const u8,
    state: *const CpuState,
) void {
    const wd = w.data.CPU;
    const new, const old = state.getCurrPrev();

    const fg, const bg = w.check(state, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const bit = typ.optBit(part.opt);
        if (bit & wd.opt_mask.usage != 0) {
            @as(unt.NumUnit, .{
                .n = state.usage[part.opt],
                .u = .percent,
            }).write(writer, part.wopts, part.quiet);
            continue;
        }

        if (bit & wd.opt_mask.stats != 0) {
            unt.UnitSI(
                misc.calc(
                    new.stats[part.opt - typ.CpuOpt.STATS_OPTS_OFF],
                    old.stats[part.opt - typ.CpuOpt.STATS_OPTS_OFF],
                    part.diff,
                ),
            ).write(writer, part.wopts, part.quiet);
            continue;
        }

        const needed = new.nr_cpux_entries * @max(BRLBARS[0][0].len, BLKBARS[0].len);
        if (writer.unusedCapacityLen() < needed) {
            @branchHint(.unlikely);
            break;
        }

        const buffer = writer.buffer;
        var pos = writer.end;

        const opt: typ.CpuOpt = @enumFromInt(part.opt);
        switch (opt.castTo(typ.CpuOpt.SpecialOpts)) {
            .brlbars => {
                var left: u32 = 0;
                var right: u32 = 0;

                for (1..1 + new.nr_cpux_entries) |i| {
                    if (i & 1 == 1) {
                        left = barIntensity(new.entries[i], old.entries[i], BRLBARS.len);
                    } else {
                        right = barIntensity(new.entries[i], old.entries[i], BRLBARS[0].len);
                        buffer[pos..][0..3].* = BRLBARS[left][right];
                        pos += 3;
                    }
                }
                if (new.nr_cpux_entries & 1 == 1) {
                    buffer[pos..][0..3].* = BRLBARS[left][0];
                    pos += 3;
                }
            },
            .blkbars => {
                for (1..1 + new.nr_cpux_entries) |i| {
                    buffer[pos..][0..3].* =
                        BLKBARS[barIntensity(new.entries[i], old.entries[i], BLKBARS.len)];
                    pos += 3;
                }
            },
        }
        writer.end = pos;
    }
    wd.format.last_str.writeBytes(writer, base);
}
