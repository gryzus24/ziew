const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;

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
        const diff_total = @reduce(.Add, diff);

        if (DELTA_ZERO_CHECK and diff_total == 0) {
            @branchHint(.cold);
            return .zero;
        }

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
    intr: u64,
    ctxt: u64,
    forks: u64,
    running: u32,
    blocked: u32,
    softirq: u64,
    entries: [*]Cpu,
    nr_cpux_entries: usize,

    pub fn initZero(reg: *m.Region, nr_possible_cpus: u32) !@This() {
        // First entry is the cumulative stat of every CPU.
        const entries = try reg.frontAllocMany(Cpu, nr_possible_cpus + 1);
        for (0..entries.len) |i| entries[i] = .zero;
        return .{
            .intr = 0,
            .ctxt = 0,
            .forks = 0,
            .running = 0,
            .blocked = 0,
            .softirq = 0,
            .entries = entries.ptr,
            .nr_cpux_entries = 0,
        };
    }
};

// == private =================================================================

fn parseProcStat(buf: []const u8, new: *Stat) void {
    var cpu: usize = 0;
    var i = "cpu  ".len;
    while (true) {
        var fields: [8]u64 = undefined;
        for (0..fields.len) |fi| {
            fields[fi] = utl.atou64ForwardUntil(buf, &i, ' ');
            i += 1;
        }
        // zig fmt: off
        // User time includes guest time. Check v6.17 kernel/sched/cputime.c#L158
        //                        user        nice
        //                        system      irq         softirq     steal
        new.entries[cpu].user   = fields[0] + fields[1];
        new.entries[cpu].sys    = fields[2] + fields[5] + fields[6] + fields[7];
        new.entries[cpu].idle   = fields[3];
        new.entries[cpu].iowait = fields[4];
        // zif fmt: on

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
    i += "intr ".len;
    new.intr = utl.atou64ForwardUntil(buf, &i, ' ');

    i = buf.len - 1 - " 0 0 0 0 0 0 0 0 0 0 0\n".len;
    while (buf[i] != 'q') : (i -= 1) {}
    // i at: softir[q] 123456 2345 ...

    var j = i + "q ".len;
    new.softirq = utl.atou64ForwardUntil(buf, &j, ' ');
    i -= "\nsoftirq".len;

    new.blocked = @intCast(utl.atou64BackwardUntil(buf, &i, ' '));
    i -= "\nprocs_blocked ".len;

    new.running = @intCast(utl.atou64BackwardUntil(buf, &i, ' '));
    i -= "\nprocs_running ".len;

    new.forks = utl.atou64BackwardUntil(buf, &i, ' ');
    i -= "btime X\nprocesses ".len;

    while (buf[i] != '\n') : (i -= 1) {}
    i -= 1;

    new.ctxt = utl.atou64BackwardUntil(buf, &i, ' ');

    // Value of `Stat.nr_cpux_entries` may change - CPUs might go online/offline.
    new.nr_cpux_entries = cpu;
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
    var reg: m.Region = .init(&tmem, "cputest");
    var s: Stat = try .initZero(&reg, utl.nrPossibleCpus());
    parseProcStat(buf, &s);
    try t.expect(s.entries[0].fields[0] == 46232);
    try t.expect(s.entries[0].fields[1] == 14);
    try t.expect(s.entries[0].fields[6] == 1212);
    try t.expect(s.entries[0].fields[7] == 0);
    try t.expect(s.entries[1].fields[0] == 9483);
    try t.expect(s.entries[1].fields[2] == 1638);
    try t.expect(s.entries[12].fields[0] == 858);
    try t.expect(s.entries[12].fields[1] == 0);
    try t.expect(s.entries[12].fields[6] == 123);
    try t.expect(s.entries[12].fields[7] == 0);
    try t.expect(s.intr == 1894596);
    try t.expect(s.ctxt == 3055158);
    try t.expect(s.forks == 8594);
    try t.expect(s.running == 1);
    try t.expect(s.blocked == 0);
    try t.expect(s.softirq == 4426117);
}

const BRLBARS: [5][5][3]u8 = .{
    .{ "⠀".*, "⢀".*, "⢠".*, "⢰".*, "⢸".* },
    .{ "⡀".*, "⣀".*, "⣠".*, "⣰".*, "⣸".* },
    .{ "⡄".*, "⣄".*, "⣤".*, "⣴".*, "⣼".* },
    .{ "⡆".*, "⣆".*, "⣦".*, "⣶".*, "⣾".* },
    .{ "⡇".*, "⣇".*, "⣧".*, "⣷".*, "⣿".* },
};

fn brlBarIntensity(new: Cpu, old: Cpu) u32 {
    const pct = new.delta(old).all;

    if (pct.u == 0) return 0;
    return switch (pct.whole()) {
        0...25 => 1,
        26...50 => 2,
        51...75 => 3,
        else => 4,
    };
}

const BLKBARS: [9][3]u8 = .{
    "⠀".*, "▁".*, "▂".*, "▃".*, "▄".*, "▅".*, "▆".*, "▇".*, "█".*,
};

fn blkBarIntensity(new: Cpu, old: Cpu) u32 {
    const pct = new.delta(old).all;

    if (pct.u == 0) return 0;
    const part = comptime unt.F5608.init(100).div(8).u;
    const ret = 1 + (pct.u - 1) / part;
    return @intCast(ret);
}

// == public ==================================================================

pub const CpuState = struct {
    left: Stat,
    right: Stat,
    left_newest: bool,

    usage_pct: Cpu.Delta,
    usage_abs: Cpu.Delta,

    proc_stat: fs.File,

    pub fn init(reg: *m.Region) !CpuState {
        const nr_cpus = utl.nrPossibleCpus();
        const left: Stat = try .initZero(reg, nr_cpus);
        const right: Stat = try .initZero(reg, nr_cpus);
        return .{
            .left = left,
            .right = right,
            .left_newest = false,
            .usage_pct = .zero,
            .usage_abs = .zero,
            .proc_stat = fs.cwd().openFileZ("/proc/stat", .{}) catch |e| {
                log.fatal(&.{ "open: /proc/stat: ", @errorName(e) });
            },
        };
    }

    pub fn checkPairs(self: @This(), ac: color.Active, base: [*]const u8) color.Hex {
        const new, const old = self.getNewOldPtrs();

        return color.firstColorGEThreshold(
            switch (@as(typ.CpuOpt.ColorSupported, @enumFromInt(ac.opt))) {
                .@"%all" => self.usage_pct.all.roundAndTruncate(),
                .@"%user" => self.usage_pct.user.roundAndTruncate(),
                .@"%sys" => self.usage_pct.sys.roundAndTruncate(),
                .@"%iowait" => self.usage_pct.iowait.roundAndTruncate(),
                .forks => new.forks - old.forks,
                .running => new.running,
                .blocked => new.blocked,
            },
            ac.pairs.get(base),
        );
    }

    fn getNewOldPtrs(self: *const @This()) struct { *Stat, *Stat } {
        return if (self.left_newest)
            .{ @constCast(&self.left), @constCast(&self.right) }
        else
            .{ @constCast(&self.right), @constCast(&self.left) };
    }

    fn newStateFlip(self: *@This()) struct { *Stat, *Stat } {
        self.left_newest = !self.left_newest;
        return self.getNewOldPtrs();
    }
};

pub fn update(state: *CpuState) void {
    var buf: [2 * 4096]u8 = undefined;

    const nr_read = state.proc_stat.pread(&buf, 0) catch |e| {
        log.fatal(&.{ "CPU: pread: ", @errorName(e) });
    };
    if (nr_read == buf.len)
        log.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    const new_stat, const old_stat = state.newStateFlip();

    parseProcStat(buf[0..nr_read], new_stat);

    const new = new_stat.entries[0];
    const old = old_stat.entries[0];
    state.usage_pct = new.delta(old);
    state.usage_abs = new.deltaN(old, @intCast(new_stat.nr_cpux_entries));
}

pub noinline fn widget(
    writer: *io.Writer,
    state: *const CpuState,
    w: *const typ.Widget,
    base: [*]const u8,
) void {
    const wd = w.wid.CPU;
    const new, const old = state.getNewOldPtrs();

    const fg, const bg = w.check(state, base);
    utl.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const cpuopt: typ.CpuOpt = @enumFromInt(part.opt);
        if (cpuopt == .brlbars) {
            // Yes, I know it's off by one.
            const needed = new.nr_cpux_entries * BRLBARS[0][0].len;
            if (writer.unusedCapacityLen() < needed) {
                @branchHint(.unlikely);
                break;
            }

            var left: u32 = 0;
            var right: u32 = 0;

            const buffer = writer.buffer;
            var pos = writer.end;
            for (1..1 + new.nr_cpux_entries) |i| {
                if (i & 1 == 1) {
                    left = brlBarIntensity(new.entries[i], old.entries[i]);
                } else {
                    right = brlBarIntensity(new.entries[i], old.entries[i]);
                    buffer[pos..][0..3].* = BRLBARS[left][right];
                    pos += 3;
                }
            }
            if (new.nr_cpux_entries & 1 == 1) {
                buffer[pos..][0..3].* = BRLBARS[left][0];
                pos += 3;
            }
            writer.end = pos;
            continue;
        } else if (cpuopt == .blkbars) {
            const needed = new.nr_cpux_entries * BLKBARS[0].len;
            if (writer.unusedCapacityLen() < needed) {
                @branchHint(.unlikely);
                break;
            }

            const buffer = writer.buffer;
            var pos = writer.end;
            for (1..1 + new.nr_cpux_entries) |i| {
                buffer[pos..][0..3].* =
                    BLKBARS[blkBarIntensity(new.entries[i], old.entries[i])];
                pos += 3;
            }
            writer.end = pos;
            continue;
        }
        const d = part.diff;
        const nu: unt.NumUnit = switch (cpuopt) {
            // zig fmt: off
            .@"%all"    => .{ .n = state.usage_pct.all,    .u = .percent },
            .@"%user"   => .{ .n = state.usage_pct.user,   .u = .percent },
            .@"%sys"    => .{ .n = state.usage_pct.sys,    .u = .percent },
            .@"%iowait" => .{ .n = state.usage_pct.iowait, .u = .percent },
            .all        => .{ .n = state.usage_abs.all,    .u = .percent },
            .user       => .{ .n = state.usage_abs.user,   .u = .percent },
            .sys        => .{ .n = state.usage_abs.sys,    .u = .percent },
            .iowait     => .{ .n = state.usage_abs.iowait, .u = .percent },
            .intr       => unt.UnitSI(utl.calc(new.intr, old.intr, d)),
            .ctxt       => unt.UnitSI(utl.calc(new.ctxt, old.ctxt, d)),
            .forks      => unt.UnitSI(utl.calc(new.forks, old.forks, d)),
            .running    => unt.UnitSI(new.running),
            .blocked    => unt.UnitSI(new.blocked),
            .softirq    => unt.UnitSI(utl.calc(new.softirq, old.softirq, d)),
            .brlbars    => unreachable,
            .blkbars    => unreachable,
            // zig fmt: on
        };
        nu.write(writer, part.wopts, part.quiet);
    }
    wd.format.last_str.writeBytes(writer, base);
}
