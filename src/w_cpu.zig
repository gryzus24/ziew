const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
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
        all: utl.F5608 = utl.F5608.init(0),
        user: utl.F5608 = utl.F5608.init(0),
        sys: utl.F5608 = utl.F5608.init(0),
    };

    pub fn delta(self: *const Cpu, oldself: *const Cpu, mul: u64) Delta {
        const u_delta = self.user() - oldself.user();
        const s_delta = self.sys() - oldself.sys();
        const i_delta = self.idle() - oldself.idle();
        const total_delta = u_delta + s_delta + i_delta;

        const u_delta_pct = u_delta * 100 * mul;
        const s_delta_pct = s_delta * 100 * mul;

        return .{
            .all = utl.F5608.init(u_delta_pct + s_delta_pct).div(total_delta),
            .user = utl.F5608.init(u_delta_pct).div(total_delta),
            .sys = utl.F5608.init(s_delta_pct).div(total_delta),
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
    cpu_entries: [1 + CPUS_MAX]Cpu = .{.{}} ** (1 + CPUS_MAX),
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

const BARS: [5][5][]const u8 = .{
    .{ "⠀", "⢀", "⢠", "⢰", "⢸" },
    .{ "⡀", "⣀", "⣠", "⣰", "⣸" },
    .{ "⡄", "⣄", "⣤", "⣴", "⣼" },
    .{ "⡆", "⣆", "⣦", "⣶", "⣾" },
    .{ "⡇", "⣇", "⣧", "⣷", "⣿" },
};

fn barIntensity(new: *const Cpu, old: *const Cpu) u32 {
    const pct = new.delta(old, 1).all;

    if (pct.u == 0) return 0;
    return switch (pct.whole()) {
        0...25 => 1,
        26...50 => 2,
        51...75 => 3,
        else => 4,
    };
}

// == public ==================================================================

pub const WidgetData = struct {
    format: typ.Format = .{},
    fg: typ.Color = .nocolor,
    bg: typ.Color = .nocolor,
};

pub const CpuState = struct {
    left: Stat = .{},
    right: Stat = .{},
    left_newest: bool = true,

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

    pub fn checkOptColors(self: @This(), oc: typ.OptColors) ?*const [7]u8 {
        const new, const old = self.getNewOldPtrs();

        return color.firstColorAboveThreshold(
            switch (@as(typ.CpuOpt.ColorSupported, @enumFromInt(oc.opt))) {
                .@"%all" => self.usage_pct.all.roundAndTruncate(),
                .@"%user" => self.usage_pct.user.roundAndTruncate(),
                .@"%sys" => self.usage_pct.sys.roundAndTruncate(),
                .forks => new.forks - old.forks,
                .running => new.running,
                .blocked => new.blocked,
            },
            oc.colors,
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

    const nread = state.proc_stat.pread(&buf, 0) catch |e| {
        utl.fatal(&.{ "CPU: pread: ", @errorName(e) });
    };
    if (nread == buf.len)
        utl.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    var new, const old = state.newStateFlip();

    parseProcStat(buf[0..nread], new);
    state.usage_pct = new.cpu_entries[0].delta(&old.cpu_entries[0], 1);
    state.usage_abs = new.cpu_entries[0].delta(&old.cpu_entries[0], new.nr_cpu_entries);
}

pub fn widget(
    stream: anytype,
    state: *const CpuState,
    w: *const typ.Widget,
) []const u8 {
    const wd = w.wid.CPU;
    const writer = stream.writer();
    const new, const old = state.getNewOldPtrs();

    utl.writeBlockStart(writer, wd.fg.getColor(state), wd.bg.getColor(state));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(writer, part.part);

        const cpuopt = @as(typ.CpuOpt, @enumFromInt(part.opt));
        if (cpuopt == .visubars) {
            var left: u32 = 0;
            var right: u32 = 0;
            for (1..1 + new.nr_cpu_entries) |i| {
                if (i & 1 == 1) {
                    left = barIntensity(&new.cpu_entries[i], &old.cpu_entries[i]);
                } else {
                    right = barIntensity(&new.cpu_entries[i], &old.cpu_entries[i]);
                    utl.writeStr(writer, BARS[left][right]);
                }
            }
            if (new.nr_cpu_entries & 1 == 1)
                utl.writeStr(writer, BARS[left][0]);

            continue;
        }
        const nu: utl.NumUnit = switch (cpuopt) {
            // zig fmt: off
            .@"%all"  => .{ .val = state.usage_pct.all,  .unit = utl.Unit.percent },
            .@"%user" => .{ .val = state.usage_pct.user, .unit = utl.Unit.percent },
            .@"%sys"  => .{ .val = state.usage_pct.sys,  .unit = utl.Unit.percent },
            .all      => .{ .val = state.usage_abs.all,  .unit = utl.Unit.cpu_percent },
            .user     => .{ .val = state.usage_abs.user, .unit = utl.Unit.cpu_percent },
            .sys      => .{ .val = state.usage_abs.sys,  .unit = utl.Unit.cpu_percent },
            .intr     => utl.UnitSI(new.intr - old.intr),
            .ctxt     => utl.UnitSI(new.ctxt - old.ctxt),
            .forks    => utl.UnitSI(new.forks - old.forks),
            .running  => utl.UnitSI(new.running),
            .blocked  => utl.UnitSI(new.blocked),
            .softirq  => utl.UnitSI(new.softirq - old.softirq),
            .visubars => unreachable,
            // zig fmt: on
        };
        nu.write(writer, part.alignment, part.precision);
    }
    utl.writeStr(writer, wd.format.part_last);
    return utl.writeBlockEnd_GetWritten(stream);
}
