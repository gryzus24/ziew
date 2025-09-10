const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;

const CPUS_MAX = 64;

const Cpu = struct {
    fields: [NR_FIELDS]u64 = .{0} ** NR_FIELDS,

    const NR_FIELDS = 8;

    pub fn user(self: @This()) u64 {
        // user time includes guest time,
        // check: v6.6-rc3/source/kernel/sched/cputime.c#L143
        //          user             nice
        return self.fields[0] + self.fields[1];
    }

    pub fn sys(self: @This()) u64 {
        //          system           irq              softirq          steal
        return self.fields[2] + self.fields[5] + self.fields[6] + self.fields[7];
    }

    pub fn idle(self: @This()) u64 {
        //          idle             iowait
        return self.fields[3] + self.fields[4];
    }

    const Delta = struct {
        all: unt.F5608 = .init(0),
        user: unt.F5608 = .init(0),
        sys: unt.F5608 = .init(0),
    };

    pub fn delta(self: *const Cpu, oldself: *const Cpu, mul: u64) Delta {
        const u_delta = self.user() - oldself.user();
        const s_delta = self.sys() - oldself.sys();
        const i_delta = self.idle() - oldself.idle();
        const total_delta = u_delta + s_delta + i_delta;

        if (total_delta == 0) {
            @branchHint(.cold);
            return .{};
        }

        const u_delta_pct = u_delta * 100 * mul;
        const s_delta_pct = s_delta * 100 * mul;

        return .{
            .all = unt.F5608.init(u_delta_pct + s_delta_pct).div(total_delta),
            .user = unt.F5608.init(u_delta_pct).div(total_delta),
            .sys = unt.F5608.init(s_delta_pct).div(total_delta),
        };
    }
};

const Stat = struct {
    intr: u64 = 0,
    ctxt: u64 = 0,
    forks: u64 = 0,
    running: u32 = 0,
    blocked: u32 = 0,
    softirq: u64 = 0,
    nr_cpu_entries: u32 = 0,
    cpu_entries: [1 + CPUS_MAX]Cpu = .{Cpu{}} ** (1 + CPUS_MAX),
};

// == private =================================================================

fn parseProcStat(buf: []const u8, new: *Stat) void {
    var cpui: u32 = 0;
    var i: usize = "cpu".len;
    while (buf[i] == ' ') : (i += 1) {}
    while (true) {
        for (0..Cpu.NR_FIELDS) |fieldi| {
            new.cpu_entries[cpui].fields[fieldi] = utl.atou64ForwardUntil(buf, &i, ' ');
            i += 1;
        }
        // cpuXX  41208 ... 1061 0 [0] 0\n
        i += 4;
        // cpuXX  41208 ... 1061 0 0 0\n[c] (best case)
        while (buf[i] <= '9') : (i += 1) {}
        if (buf[i] == 'i') break;

        i += "cpuX".len;
        while (buf[i] != ' ') : (i += 1) {}
        i += 1;
        cpui += 1;
        if (cpui == new.cpu_entries.len)
            utl.fatal(&.{"CPU: too many CPUs, recompile with higher CPUS_MAX"});
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

    // Value of `nr_cpu_entries` may change - CPUs might go online/offline.
    new.nr_cpu_entries = cpui;
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
    var s: Stat = .{};
    parseProcStat(buf, &s);
    try t.expect(s.cpu_entries[0].fields[0] == 46232);
    try t.expect(s.cpu_entries[0].fields[1] == 14);
    try t.expect(s.cpu_entries[0].fields[6] == 1212);
    try t.expect(s.cpu_entries[0].fields[7] == 0);
    try t.expect(s.cpu_entries[1].fields[0] == 9483);
    try t.expect(s.cpu_entries[1].fields[2] == 1638);
    try t.expect(s.cpu_entries[12].fields[0] == 858);
    try t.expect(s.cpu_entries[12].fields[1] == 0);
    try t.expect(s.cpu_entries[12].fields[6] == 123);
    try t.expect(s.cpu_entries[12].fields[7] == 0);
    try t.expect(s.intr == 1894596);
    try t.expect(s.ctxt == 3055158);
    try t.expect(s.forks == 8594);
    try t.expect(s.running == 1);
    try t.expect(s.blocked == 0);
    try t.expect(s.softirq == 4426117);
}

const BRLBARS: [5][5][]const u8 = .{
    .{ "⠀", "⢀", "⢠", "⢰", "⢸" },
    .{ "⡀", "⣀", "⣠", "⣰", "⣸" },
    .{ "⡄", "⣄", "⣤", "⣴", "⣼" },
    .{ "⡆", "⣆", "⣦", "⣶", "⣾" },
    .{ "⡇", "⣇", "⣧", "⣷", "⣿" },
};

fn brlBarIntensity(new: *const Cpu, old: *const Cpu) u32 {
    const pct = new.delta(old, 1).all;

    if (pct.u == 0) return 0;
    return switch (pct.whole()) {
        0...25 => 1,
        26...50 => 2,
        51...75 => 3,
        else => 4,
    };
}

const BLKBARS: [9][]const u8 = .{
    " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
};

fn blkBarIntensity(new: *const Cpu, old: *const Cpu) u32 {
    const pct = new.delta(old, 1).all;

    if (pct.u == 0) return 0;
    const part = comptime unt.F5608.init(100).div(8).u;
    const ret = 1 + (pct.u - 1) / part;
    return @intCast(ret);
}

// == public ==================================================================

pub const CpuState = struct {
    left: Stat = .{},
    right: Stat = .{},
    left_newest: bool = false,

    usage_pct: Cpu.Delta = .{},
    usage_abs: Cpu.Delta = .{},

    proc_stat: fs.File,

    pub fn init() CpuState {
        return .{
            .proc_stat = fs.cwd().openFileZ("/proc/stat", .{}) catch |e| {
                utl.fatal(&.{ "open: /proc/stat: ", @errorName(e) });
            },
        };
    }

    pub fn checkPairs(self: @This(), ac: color.Color.Active) color.Color.Data {
        const new, const old = self.getNewOldPtrs();

        return color.firstColorGEThreshold(
            switch (@as(typ.CpuOpt.ColorSupported, @enumFromInt(ac.opt))) {
                .@"%all" => self.usage_pct.all.roundAndTruncate(),
                .@"%user" => self.usage_pct.user.roundAndTruncate(),
                .@"%sys" => self.usage_pct.sys.roundAndTruncate(),
                .forks => new.forks - old.forks,
                .running => new.running,
                .blocked => new.blocked,
            },
            ac.pairs,
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
    var buf: [4096 << 1]u8 = undefined;

    const nr_read = state.proc_stat.pread(&buf, 0) catch |e| {
        utl.fatal(&.{ "CPU: pread: ", @errorName(e) });
    };
    if (nr_read == buf.len)
        utl.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    var new, const old = state.newStateFlip();

    parseProcStat(buf[0..nr_read], new);
    state.usage_pct = new.cpu_entries[0].delta(&old.cpu_entries[0], 1);
    state.usage_abs = new.cpu_entries[0].delta(&old.cpu_entries[0], new.nr_cpu_entries);
}

pub fn widget(
    writer: *io.Writer,
    state: *const CpuState,
    w: *const typ.Widget,
) []const u8 {
    const wd = w.wid.CPU;
    const new, const old = state.getNewOldPtrs();

    utl.writeBlockBeg(writer, wd.fg.get(state), wd.bg.get(state));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(writer, part.str);

        const cpuopt: typ.CpuOpt = @enumFromInt(part.opt);
        if (cpuopt == .brlbars) {
            var left: u32 = 0;
            var right: u32 = 0;
            for (1..1 + new.nr_cpu_entries) |i| {
                if (i & 1 == 1) {
                    left = brlBarIntensity(&new.cpu_entries[i], &old.cpu_entries[i]);
                } else {
                    right = brlBarIntensity(&new.cpu_entries[i], &old.cpu_entries[i]);
                    utl.writeStr(writer, BRLBARS[left][right]);
                }
            }
            if (new.nr_cpu_entries & 1 == 1)
                utl.writeStr(writer, BRLBARS[left][0]);

            continue;
        } else if (cpuopt == .blkbars) {
            for (1..1 + new.nr_cpu_entries) |i| {
                utl.writeStr(
                    writer,
                    BLKBARS[blkBarIntensity(&new.cpu_entries[i], &old.cpu_entries[i])],
                );
            }
            continue;
        }
        const d = part.flags.diff;
        const nu: unt.NumUnit = switch (cpuopt) {
            // zig fmt: off
            .@"%all"  => .{ .n = state.usage_pct.all,  .u = .percent },
            .@"%user" => .{ .n = state.usage_pct.user, .u = .percent },
            .@"%sys"  => .{ .n = state.usage_pct.sys,  .u = .percent },
            .all      => .{ .n = state.usage_abs.all,  .u = .percent },
            .user     => .{ .n = state.usage_abs.user, .u = .percent },
            .sys      => .{ .n = state.usage_abs.sys,  .u = .percent },
            .intr     => unt.UnitSI(utl.calc(new.intr, old.intr, d)),
            .ctxt     => unt.UnitSI(utl.calc(new.ctxt, old.ctxt, d)),
            .forks    => unt.UnitSI(utl.calc(new.forks, old.forks, d)),
            .running  => unt.UnitSI(new.running),
            .blocked  => unt.UnitSI(new.blocked),
            .softirq  => unt.UnitSI(utl.calc(new.softirq, old.softirq, d)),
            .brlbars  => unreachable,
            .blkbars  => unreachable,
            // zig fmt: on
        };
        nu.write(writer, part.wopts, part.flags.quiet);
    }
    utl.writeStr(writer, wd.format.part_last);
    return utl.writeBlockEnd(writer);
}
