const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const math = std.math;
const mem = std.mem;

pub const NCPUS_MAX = 64;

pub const Cpu = struct {
    pub const NFIELDS = 8;

    fields: [NFIELDS]u64 = .{0} ** NFIELDS,

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

    pub fn allUserSysDelta(
        self: *const Cpu,
        oldself: *const Cpu,
        ncpus: usize,
        out: *[3]utl.F5608,
    ) void {
        const user_delta = self.user() - oldself.user();
        const sys_delta = self.sys() - oldself.sys();
        const idle_delta = self.idle() - oldself.idle();
        const total_delta = user_delta + sys_delta + idle_delta;

        const u_pdelta = user_delta * 100 * ncpus;
        const s_pdelta = sys_delta * 100 * ncpus;

        out[0] = utl.F5608.init(u_pdelta + s_pdelta).div(total_delta);
        out[1] = utl.F5608.init(u_pdelta).div(total_delta);
        out[2] = utl.F5608.init(s_pdelta).div(total_delta);
    }
};

pub const Stat = struct {
    ncpus: u32 = 0,
    intr: u64 = 0,
    ctxt: u64 = 0,
    cpus: [1 + NCPUS_MAX]Cpu = .{.{}} ** (1 + NCPUS_MAX),
};

pub const CpuState = struct {
    slots: [8]utl.F5608 = .{utl.F5608.init(0)} ** 8,
    left_newest: bool = true,
    left: Stat = .{},
    right: Stat = .{},

    fn getNewOldPtrs(
        self: *const @This(),
        new: **const Stat,
        old: **const Stat,
    ) void {
        if (self.left_newest) {
            new.* = &self.left;
            old.* = &self.right;
        } else {
            new.* = &self.right;
            old.* = &self.left;
        }
    }

    fn newStateFlip(self: *@This(), new: **const Stat, old: **const Stat) void {
        self.left_newest = !self.left_newest;
        self.getNewOldPtrs(new, old);
    }

    comptime {
        var w: u8 = 0;
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.@"%all") != 0);
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.@"%user") != 1);
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.@"%sys") != 2);
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.all) != 3);
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.user) != 4);
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.sys) != 5);
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.intr) != 6);
        w |= @intFromBool(@intFromEnum(typ.CpuOpt.ctxt) != 7);
        if (w > 0) @compileError("fix CpuOpt enum field order");
    }

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            switch (@as(typ.CpuOpt, @enumFromInt(mc.opt))) {
                .@"%all" => self.slots[@intFromEnum(typ.CpuOpt.@"%all")],
                .@"%user" => self.slots[@intFromEnum(typ.CpuOpt.@"%user")],
                .@"%sys" => self.slots[@intFromEnum(typ.CpuOpt.@"%sys")],
                .all, .user, .sys, .intr, .ctxt, .visubars => unreachable,
            }.roundAndTruncate(),
            mc.colors,
        );
    }
};

fn parseProcStat(buf: []const u8, new: *Stat) void {
    var cpui: u32 = 0;
    var i: usize = "cpu".len;
    while (buf[i] == ' ') : (i += 1) {}
    while (true) {
        var nfields: u32 = 0;
        while (nfields < Cpu.NFIELDS) : (nfields += 1) {
            var j = i;
            while (buf[j] != ' ') : (j += 1) {}
            new.cpus[cpui].fields[nfields] = utl.unsafeAtou64(buf[i..j]);
            i = j + 1;
        }
        // cpuXX  41208 ... 1061 0 [0] 0\n
        i += 4;
        // cpuXX  41208 ... 1061 0 0 0\n[c]
        while (buf[i] <= '9') : (i += 1) {}
        if (buf[i] == 'i') break;

        i += "cpuX".len;
        while (buf[i] != ' ') : (i += 1) {}
        i += 1;
        cpui += 1;
    }
    i += "intr ".len;
    var j = i;
    while (buf[j] != ' ') : (j += 1) {}
    new.intr = utl.unsafeAtou64(buf[i..j]);
    i = j + 1;
    // intr 12345[ ]0 678 ...

    while (buf[i] <= '9') : (i += "ctxt".len) {}
    while (buf[i] != ' ') : (i += 1) {}
    i += 1;
    // ctxt [1]2345\n

    j = i;
    while (buf[j] != '\n') : (j += 1) {}
    new.ctxt = utl.unsafeAtou64(buf[i..j]);

    // value of ncpus can change - CPUs might go offline/online
    new.ncpus = cpui;
    if (new.ncpus > NCPUS_MAX)
        utl.fatal(&.{"CPU: too many CPUs, recompile"});
}

pub fn update(stat: *const fs.File, state: *CpuState) void {
    var buf: [4096 << 1]u8 = undefined;

    const nread = stat.pread(&buf, 0) catch |err| {
        utl.fatal(&.{ "CPU: pread: ", @errorName(err) });
    };
    if (nread == buf.len)
        utl.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    var new: *Stat = undefined;
    var old: *Stat = undefined;
    state.newStateFlip(&new, &old);

    parseProcStat(&buf, new);
    new.cpus[0].allUserSysDelta(&old.cpus[0], 1, state.slots[0..3]);
    new.cpus[0].allUserSysDelta(&old.cpus[0], new.ncpus, state.slots[3..6]);
    state.slots[6] = utl.F5608.init(new.intr - old.intr);
    state.slots[7] = utl.F5608.init(new.ctxt - old.ctxt);
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
        \\intr 1894596 0 33004 0 0 0 0 0 0 0 8008 0 0 182 0 0
        \\ctxt 3055158
        \\btime 17137
    ;
    var s: Stat = .{};
    parseProcStat(buf, &s);
    try t.expect(s.cpus[0].fields[0] == 46232);
    try t.expect(s.cpus[0].fields[1] == 14);
    try t.expect(s.cpus[0].fields[6] == 1212);
    try t.expect(s.cpus[0].fields[7] == 0);
    try t.expect(s.cpus[1].fields[0] == 9483);
    try t.expect(s.cpus[1].fields[2] == 1638);
    try t.expect(s.cpus[12].fields[0] == 858);
    try t.expect(s.cpus[12].fields[1] == 0);
    try t.expect(s.cpus[12].fields[6] == 123);
    try t.expect(s.cpus[12].fields[7] == 0);
    try t.expect(s.intr == 1894596);
    try t.expect(s.ctxt == 3055158);
}

const BARS: [5][5][]const u8 = .{
    .{ "⠀", "⢀", "⢠", "⢰", "⢸" },
    .{ "⡀", "⣀", "⣠", "⣰", "⣸" },
    .{ "⡄", "⣄", "⣤", "⣴", "⣼" },
    .{ "⡆", "⣆", "⣦", "⣶", "⣾" },
    .{ "⡇", "⣇", "⣧", "⣷", "⣿" },
};

fn barIndexOfDelta(new: *const Cpu, old: *const Cpu) u32 {
    var slots: [3]utl.F5608 = undefined;
    new.allUserSysDelta(old, 1, &slots);
    return switch (slots[0].whole()) {
        0 => 0,
        1...25 => 1,
        26...50 => 2,
        51...75 => 3,
        else => 4,
    };
}

pub fn widget(
    stream: anytype,
    state: *const CpuState,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    const writer = stream.writer();

    utl.writeBlockStart(writer, fg.getColor(state), bg.getColor(state));
    utl.writeStr(writer, wf.parts[0]);
    for (wf.iterOpts(), wf.iterParts()[1..]) |*opt, *part| {
        if (@as(typ.CpuOpt, @enumFromInt(opt.opt)) == .visubars) {
            var new: *const Stat = undefined;
            var old: *const Stat = undefined;
            state.getNewOldPtrs(&new, &old);

            var lbari: usize = 0;
            var rbari: usize = 0;
            for (1..1 + new.ncpus) |i| {
                if (i & 1 == 1) {
                    lbari = barIndexOfDelta(&new.cpus[i], &old.cpus[i]);
                } else {
                    rbari = barIndexOfDelta(&new.cpus[i], &old.cpus[i]);
                    utl.writeStr(writer, BARS[lbari][rbari]);
                }
            }
            if (new.ncpus & 1 == 1)
                utl.writeStr(writer, BARS[lbari][0]);
        } else {
            const value = state.slots[opt.opt];
            const nu: utl.NumUnit = switch (@as(typ.CpuOpt, @enumFromInt(opt.opt))) {
                .@"%all", .@"%user", .@"%sys" => .{ .val = value, .unit = utl.Unit.percent },
                .all, .user, .sys => .{ .val = value, .unit = utl.Unit.cpu_percent },
                .intr, .ctxt => utl.UnitSI(value.whole()),
                .visubars => unreachable,
            };
            nu.write(writer, opt.alignment, opt.precision);
        }
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
