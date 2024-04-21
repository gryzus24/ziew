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
    fields: [8]u64 = .{0} ** 8,

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
    pub fn pall(self: *const @This()) utl.F5608 {
        return self.slots[@intFromEnum(typ.CpuOpt.@"%all")];
    }
    pub fn puser(self: *const @This()) utl.F5608 {
        return self.slots[@intFromEnum(typ.CpuOpt.@"%user")];
    }
    pub fn psys(self: *const @This()) utl.F5608 {
        return self.slots[@intFromEnum(typ.CpuOpt.@"%sys")];
    }

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            switch (@as(typ.CpuOpt, @enumFromInt(mc.opt))) {
                .@"%all" => self.pall(),
                .@"%user" => self.puser(),
                .@"%sys" => self.psys(),
                .all, .user, .sys, .intr, .ctxt, .visubars => unreachable,
            }.roundAndTruncate(),
            mc.colors,
        );
    }
};

fn unsafeParseCpuLine(line: []const u8, out: *Cpu) void {
    var i: usize = "cpu".len;
    while (line[i] != ' ') : (i += 1) {}

    var nvals: usize = 0;
    var ndigits: usize = 0;
    while (true) : (i += 1) switch (line[i]) {
        ' ' => {
            if (ndigits > 0) {
                out.fields[nvals] = utl.unsafeAtou64(line[i - ndigits .. i]);
                nvals += 1;
                if (nvals == out.fields.len) break;
                ndigits = 0;
            }
        },
        '0'...'9' => ndigits += 1,
        else => {},
    };
}

pub fn update(stat: *const fs.File, state: *CpuState) void {
    var statbuf: [4096 << 1]u8 = undefined;

    const nread = stat.pread(&statbuf, 0) catch |err| {
        utl.fatal(&.{ "CPU: pread: ", @errorName(err) });
    };
    if (nread == statbuf.len)
        utl.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    var new: *Stat = undefined;
    var old: *Stat = undefined;
    state.newStateFlip(&new, &old);

    var cpui: u32 = 0;
    var lines = mem.tokenizeScalar(u8, statbuf[0..nread], '\n');
    while (lines.next()) |line| switch (line[0]) {
        'c' => {
            if (line[1] == 'p') {
                unsafeParseCpuLine(line, &new.cpus[cpui]);
                cpui += 1;
            } else if (line[1] == 't') {
                new.ctxt = utl.unsafeAtou64(line["ctxt ".len..]);
            }
        },
        'i' => {
            var i: usize = "intr ".len;
            while (line[i] != ' ') : (i += 1) {}
            new.intr = utl.unsafeAtou64(line["intr ".len..i]);
        },
        else => {},
    };
    // value of ncpus can change - CPUs might go offline/online
    new.ncpus = cpui - 1;
    if (new.ncpus > NCPUS_MAX)
        utl.fatal(&.{"CPU: too many CPUs, recompile"});

    new.cpus[0].allUserSysDelta(&old.cpus[0], 1, state.slots[0..3]);
    new.cpus[0].allUserSysDelta(&old.cpus[0], new.ncpus, state.slots[3..6]);
    state.slots[6] = utl.F5608.init(new.intr - old.intr);
    state.slots[7] = utl.F5608.init(new.ctxt - old.ctxt);
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
            var value: utl.F5608 = state.slots[opt.opt];
            const value_type = @as(
                utl.F5608.AlignmentValueType,
                switch (@as(typ.CpuOpt, @enumFromInt(opt.opt))) {
                    .@"%all", .@"%user", .@"%sys" => .percent,
                    else => .size, // FIXME: not really a size
                },
            );
            value.write(writer, value_type, opt.alignment, opt.precision);
            if (value_type == .percent)
                utl.writeStr(writer, &[1]u8{'%'});
            utl.writeStr(writer, part.*);
        }
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
