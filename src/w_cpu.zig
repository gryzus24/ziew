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

// == configurable ============================================================

// If you trust the kernel to be tracking CPU usage sanely, and your userspace
// to not tell ziew to refresh multiple times within ~10 ms then you can set
// the below option to false to avoid a division-by-zero paranoia check.
const DELTA_ZERO_CHECK = true;

// The higher the "rank zero step size" the higher the measured CPU usage has
// to be to *not* be considered idle (i.e. not be considered "rank zero"):
//   - 1, any CPU usage is reported as not idle (only zero CPU usage is idle),
//   - FRAC_MASK (~255), CPU usage <1% is reported as idle.
const CPU_RANK_ZERO_STEP_SIZE = unt.F5608.FRAC_MASK;

// If the width of Block and Braille characters is not consistent for the font
// you use, set the below option to true to replace the blank Braille pattern
// with a space character - setting it to false is only a micro-opimization.
const BLK_RANK_ZERO_IS_SPACE = true;

// ============================================================================

const BAR_WIDTH = 3;

const BRL = struct {
    const RANGE = 5;
    //                                    "⠀"       "⡀"       "⡄"       "⡆"       "⡇"
    const BARS_LEFT: [RANGE]u24 = .{ 0x80a0e2, 0x80a1e2, 0x84a1e2, 0x86a1e2, 0x87a1e2 };
    //                                    "⠀"       "⢀"       "⢠"      "⢰"        "⢸"
    const BARS_RIGH: [RANGE]u24 = .{ 0x80a0e2, 0x80a2e2, 0xa0a2e2, 0xb0a2e2, 0xb8a2e2 };

    inline fn rankChar(left: u32, righ: u32) [BAR_WIDTH]u8 {
        return @bitCast(BARS_LEFT[left] | BARS_RIGH[righ]);
    }
};

const BLK = struct {
    const RANGE = 9;

    const BARS: [RANGE][BAR_WIDTH]u8 = .{
        if (BLK_RANK_ZERO_IS_SPACE) "   ".* else "⠀".*,
        "▁".*,
        "▂".*,
        "▃".*,
        "▄".*,
        "▅".*,
        "▆".*,
        "▇".*,
        "█".*,
    };

    inline fn rankIncrement(rank: u32) usize {
        return if (BLK_RANK_ZERO_IS_SPACE)
            if (rank == 0) 1 else BAR_WIDTH
        else
            BAR_WIDTH;
    }
};

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

    // zig fmt: off
    const __off   = typ.Opts.Cpu.STATS_OFF;
    const intr    = @intFromEnum(typ.Opts.Cpu.intr) - __off;
    const softirq = @intFromEnum(typ.Opts.Cpu.softirq) - __off;
    const blocked = @intFromEnum(typ.Opts.Cpu.blocked) - __off;
    const running = @intFromEnum(typ.Opts.Cpu.running) - __off;
    const forks   = @intFromEnum(typ.Opts.Cpu.forks) - __off;
    const ctxt    = @intFromEnum(typ.Opts.Cpu.ctxt) - __off;

    comptime {
        std.debug.assert(intr    == 0);
        std.debug.assert(softirq == 1);
        std.debug.assert(blocked == 2);
        std.debug.assert(running == 3);
        std.debug.assert(forks   == 4);
        std.debug.assert(ctxt    == 5);
    }
    // zig fmt: on

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

const Graph = struct {
    cur: u32,
    mask: u32,
    ring: typ.FlexField([*]u8),

    const SampleSize = u8;
    const SAMPLES_PER_BYTE = 8 / @bitSizeOf(SampleSize);
    comptime {
        const a = @bitSizeOf(SampleSize);
        std.debug.assert(a & (a - 1) == 0);
    }

    fn init(reg: *umem.Region, width: u3) !*Graph {
        const ring_size = (@as(usize, 1) << width) / SAMPLES_PER_BYTE;
        const self = try reg.alloc(Graph, .front);
        const ring = try reg.allocMany(u8, ring_size, .front);
        self.* = .{
            .cur = 0,
            .mask = (@as(u32, 1) << width) - 1,
            .ring = undefined,
        };
        @memset(ring, 0);
        return self;
    }

    inline fn offMaskShiftU4(i: usize) struct { usize, u8, u3 } {
        comptime std.debug.assert(@bitSizeOf(SampleSize) == 4);
        const shift: u3 = @intCast((i & 1) * 4);
        return .{ i >> 1, @shlExact(@as(u8, 0b1111), shift), shift };
    }

    inline fn blot(self: *@This(), __n: SampleSize) void {
        const n: u8 = __n;
        const cur = self.cur;
        const ring = self.ring.getMutable();
        switch (SampleSize) {
            u8 => ring[cur] = n,
            u4 => {
                const off, const mask, const shift = offMaskShiftU4(cur);
                ring[off] = (ring[off] & ~mask) | @shlExact(n, shift);
            },
            else => @compileError("Unimplemented SampleSize"),
        }
        self.cur = (cur + 1) & self.mask;
    }

    inline fn at(self: *const @This(), __i: usize) SampleSize {
        const i = __i & self.mask;
        const ring = self.ring.get();
        return switch (SampleSize) {
            u8 => ring[i],
            u4 => {
                const off, const mask, const shift = offMaskShiftU4(i);
                return @intCast(@shrExact(ring[off] & mask, shift));
            },
            else => @compileError("Unimplemented SampleSize"),
        };
    }
};

// == private =================================================================

fn atouVecForwardUntil(buf: []const u8, i: usize, char: u8) struct { u64, usize } {
    const V = @Vector(8, u8);
    const exp10: [16]u32 = .{
        100_000_000, 10_000_000, 1_000_000, 100_000,
        10_000,      1_000,      100,       10,
        1,           0,          0,         0,
        0,           0,          0,         0,
    };
    var j = i;
    var r: u64 = 0;
    while (true) {
        const block: V = buf[j..][0..8].*;
        const digits = block & @as(V, @splat(0x0f));
        const mask: u8 = @bitCast(block == @as(V, @splat(char)));
        const len: u8 = @ctz(mask);
        r *= exp10[8 - len];
        r += @reduce(.Add, digits * exp10[1 + 8 - len ..][0..8].*);
        j += len;
        if (len != 8 or buf[j] == char) break;
    }
    return .{ r, j };
}

inline fn parseProcStat(buf: []const u8, out: *Stat) void {
    const Block = @Vector(32, u8);
    const spaces: Block = @splat(' ');
    const newlines: Block = @splat('\n');

    var cpu: usize = 0;
    var i = "cpu  ".len;
    while (true) {
        var fields: [8]u64 = undefined;
        for (0..fields.len) |fi| {
            fields[fi], i = atouVecForwardUntil(buf, i, ' ');
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

        // Read 32 bytes in hope there are at least two spaces there.
        //   "0 0\ncpuXX YYYY"[i+1..]
        const block: Block = buf[i + 1 ..][0..32].*;
        const mask: u32 = @bitCast(block == spaces);

        // Jump to the second space-1 (-1 because of buf[i+1..]).
        i += @ctz(mask & (mask - 1));
        if (buf[i] == 'r') {
            break;
        }
        i += 2;
        cpu += 1;
    }
    // Value of `Stat.nr_cpux_entries` may change - CPUs might go online/offline.
    out.nr_cpux_entries = cpu;

    i += 2;
    out.stats[Stat.intr], _ = ustr.atouForwardUntil(u64, buf, i, ' ');

    // We have some numbers to skip, use this opportunity to align the pointer
    // and make sure we don't catch the $'\n' at `buf[buf.len - 1]`.
    i = (buf.len - 1) & ~@as(usize, 31);
    while (true) : (i -= 32) {
        const block: Block = buf[i - 32 ..][0..32].*;
        const mask: u32 = @bitCast(block == newlines);
        if (mask != 0) {
            i -= @clz(mask);
            i += "softirq ".len;
            break;
        }
    }
    out.stats[Stat.softirq], _ = ustr.atouForwardUntil(u64, buf, i, ' ');
    i -= "\nsoftirq X".len;

    out.stats[Stat.blocked], i = ustr.atouBackwardUntil(u64, buf, i, ' ');
    i -= "\nprocs_blocked ".len;

    out.stats[Stat.running], i = ustr.atouBackwardUntil(u64, buf, i, ' ');
    i -= "\nprocs_running ".len;

    out.stats[Stat.forks], i = ustr.atouBackwardUntil(u64, buf, i, ' ');
    i -= "\nprocesses ".len;
    i -= "btime 123456789A".len;

    while (buf[i] != '\n') : (i -= 1) {}
    i -= 1;

    out.stats[Stat.ctxt], _ = ustr.atouBackwardUntil(u64, buf, i, ' ');
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
        \\intr 1894596 0 330 0 0 0 0 0 0 0 88 0 0 18 0 0 0 0 0 0 0 0 0 0 0
        \\ctxt 3055158
        \\btime 1799999999
        \\processes 8594
        \\procs_running 1
        \\procs_blocked 0
        \\softirq 4426117 14101 3005 4 13791 895 0 4659 16049 6 4977
        \\
    ;
    var stack: [4096]u8 align(32) = undefined;
    var reg: umem.Region = .init(&stack, "cpu-test");

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

inline fn cpuUsageRank(curr: Cpu, prev: Cpu, comptime range: comptime_int) u8 {
    comptime std.debug.assert(2 <= range and range <= 100);
    comptime std.debug.assert(CPU_RANK_ZERO_STEP_SIZE > 0);
    const step = comptime unt.F5608.init(100).div(range - 1).u;
    const off = step - CPU_RANK_ZERO_STEP_SIZE;
    const u_max = (range - 1) * step;

    const pct = curr.delta(prev).all;
    const u = @min(pct.u, u_max);
    const q, _ = udiv.cMultShiftDivMod(u + off, step, u_max + off);
    return @intCast(q);
}

inline fn nrCpusOnlineChanged(curr: *const Stat, prev: *const Stat) bool {
    return curr.nr_cpux_entries != prev.nr_cpux_entries;
}

// == public ==================================================================

pub const State = struct {
    stats: [2]Stat,

    usage_pct: [4]unt.F5608,
    usage_abs: [4]unt.F5608,
    graph_brl: *Graph,
    graph_blk: *Graph,
    enabled: Flags,

    curr: u32,
    fd: linux.fd_t,

    const Flags = packed struct(u8) {
        pct: bool,
        abs: bool,
        brl: bool,
        blk: bool,
        _: u4 = 0,

        pub const none: Flags = .{
            .pct = false,
            .abs = false,
            .brl = false,
            .blk = false,
        };
    };

    pub fn init(reg: *umem.Region, widgets: []const typ.Widget) !State {
        const base = reg.head.ptr;

        var enabled: Flags = .none;
        var brl_width: u8 = 0;
        var blk_width: u8 = 0;
        for (widgets) |*w| {
            if (w.id == .CPU) {
                var it: typ.OptIterator = .init(w, base);
                while (it.next()) |e| {
                    if (typ.optBit(e.opt) & typ.Opts.Cpu.USAGE_MASK != 0) {
                        if (e.pct) {
                            enabled.pct = true;
                        } else {
                            enabled.abs = true;
                        }
                    } else if (e.opt == @intFromEnum(typ.Opts.Cpu.brlgraph)) {
                        enabled.brl = true;
                        brl_width = e.width;
                    } else if (e.opt == @intFromEnum(typ.Opts.Cpu.blkgraph)) {
                        enabled.blk = true;
                        blk_width = e.width;
                    }
                }
            }
        }
        const nr_cpus = misc.nrPossibleCpus();
        const a: Stat = try .initZero(reg, nr_cpus);
        const b: Stat = try .initZero(reg, nr_cpus);

        var graph_brl: *Graph = undefined;
        if (enabled.brl)
            graph_brl = try .init(reg, @intCast(brl_width));

        var graph_blk: *Graph = undefined;
        if (enabled.blk)
            graph_blk = try .init(reg, @intCast(blk_width));

        return .{
            .stats = .{ a, b },
            .usage_pct = @splat(.init(0)),
            .usage_abs = @splat(.init(0)),
            .graph_brl = graph_brl,
            .graph_blk = graph_blk,
            .enabled = enabled,
            .curr = 0,
            .fd = uio.open0("/proc/stat") catch return error.NoProc,
        };
    }

    pub fn checkPairs(
        self: *const @This(),
        opt: u8,
        pct: bool,
        pairs: []const color.Active.Pair,
    ) color.Hex {
        const curr, const prev = typ.constCurrPrev(Stat, &self.stats, self.curr);
        const opt_color: typ.Opts.Cpu.ColorSupported = @enumFromInt(opt);
        const id = opt -% typ.Opts.Cpu.STATS_OFF;

        const value = switch (opt_color) {
            .all, .user, .sys, .iowait => blk: {
                const ptr = if (pct) &self.usage_pct else &self.usage_abs;
                break :blk ptr[opt].roundU24AndTruncate();
            },
            .intr, .softirq, .blocked, .running, .forks, .ctxt => blk: {
                var stat = curr.stats[id];
                switch (opt_color) {
                    .intr, .softirq, .forks, .ctxt => stat -= prev.stats[id],
                    else => {},
                }
                break :blk stat;
            },
        };
        return color.firstColorGEThreshold(value, pairs);
    }
};

pub fn update(state: *State) error{ReadError}!void {
    var buf: [8192]u8 = undefined;
    const n = try uio.pread(state.fd, &buf, 0);
    if (n == buf.len) log.fatal(&.{"CPU: /proc/stat doesn't fit in 2 pages"});

    state.curr ^= 1;
    const curr, var prev = typ.currPrev(Stat, &state.stats, state.curr);

    parseProcStat(buf[0..n], curr);
    if (nrCpusOnlineChanged(curr, prev)) {
        @branchHint(.unlikely);
        prev = curr;
    }

    const curr_cpu = curr.entries[0];
    const prev_cpu = prev.entries[0];

    if (state.enabled.pct) {
        const delta = curr_cpu.delta(prev_cpu);
        state.usage_pct[@intFromEnum(typ.Opts.Cpu.all)] = delta.all;
        state.usage_pct[@intFromEnum(typ.Opts.Cpu.user)] = delta.user;
        state.usage_pct[@intFromEnum(typ.Opts.Cpu.sys)] = delta.sys;
        state.usage_pct[@intFromEnum(typ.Opts.Cpu.iowait)] = delta.iowait;
    }
    if (state.enabled.abs) {
        const deltaN = curr_cpu.deltaN(prev_cpu, @intCast(curr.nr_cpux_entries));
        state.usage_abs[@intFromEnum(typ.Opts.Cpu.all)] = deltaN.all;
        state.usage_abs[@intFromEnum(typ.Opts.Cpu.user)] = deltaN.user;
        state.usage_abs[@intFromEnum(typ.Opts.Cpu.sys)] = deltaN.sys;
        state.usage_abs[@intFromEnum(typ.Opts.Cpu.iowait)] = deltaN.iowait;
    }
    if (state.enabled.brl) {
        const sample = cpuUsageRank(curr_cpu, prev_cpu, BRL.RANGE);
        state.graph_brl.blot(@intCast(sample));
    }
    if (state.enabled.blk) {
        const sample = cpuUsageRank(curr_cpu, prev_cpu, BLK.RANGE);
        state.graph_blk.blot(@intCast(sample));
    }
}

pub fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    parts: []const typ.Format.Part,
    base: [*]const u8,
    state: *const State,
) void {
    const interval = w.readInterval(base);
    const curr, var prev = typ.constCurrPrev(Stat, &state.stats, state.curr);
    if (nrCpusOnlineChanged(curr, prev)) {
        @branchHint(.unlikely);
        prev = curr;
    }

    const fg, const bg = w.check(state, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (parts) |*part| {
        part.str.writeBytes(writer, base);

        const bit = typ.optBit(part.opt);
        if (bit & (typ.Opts.Cpu.USAGE_MASK | typ.Opts.Cpu.STATS_MASK) != 0) {
            var negative = false;
            var nu: unt.NumUnit = undefined;

            if (bit & typ.Opts.Cpu.USAGE_MASK != 0) {
                nu = .{
                    .n = if (part.flags.pct)
                        state.usage_pct[part.opt]
                    else
                        state.usage_abs[part.opt],
                    .u = .percent,
                };
            } else {
                const value, negative = typ.calcWithOverflow(
                    curr.stats[part.opt - typ.Opts.Cpu.STATS_OFF],
                    prev.stats[part.opt - typ.Opts.Cpu.STATS_OFF],
                    interval,
                    part.flags,
                );
                nu = unt.UnitSI(value);
            }
            const wopts = part.wopts.copyAndSetNegative(negative);
            nu.write(writer, wopts);
            continue;
        }

        const buffer = writer.buffer;
        var pos = writer.end;

        const opt: typ.Opts.Cpu.Special = @enumFromInt(part.opt);
        switch (opt) {
            .brlbars, .blkbars => {
                var need = curr.nr_cpux_entries * BAR_WIDTH;
                if (opt == .brlbars)
                    need /= 2;
                if (need > writer.unusedCapacityLen()) {
                    @branchHint(.unlikely);
                    break;
                }
                if (opt == .brlbars) {
                    var l: u32, var r: u32 = .{ 0, 0 };
                    for (1..1 + curr.nr_cpux_entries) |i| {
                        if (i & 1 == 1) {
                            l = cpuUsageRank(curr.entries[i], prev.entries[i], BRL.RANGE);
                        } else {
                            r = cpuUsageRank(curr.entries[i], prev.entries[i], BRL.RANGE);
                            buffer[pos..][0..BAR_WIDTH].* = BRL.rankChar(l, r);
                            pos += BAR_WIDTH;
                        }
                    }
                    if (curr.nr_cpux_entries & 1 == 1) {
                        buffer[pos..][0..BAR_WIDTH].* = BRL.rankChar(l, 0);
                        pos += BAR_WIDTH;
                    }
                } else {
                    for (1..1 + curr.nr_cpux_entries) |i| {
                        const rank = cpuUsageRank(curr.entries[i], prev.entries[i], BLK.RANGE);
                        buffer[pos..][0..BAR_WIDTH].* = BLK.BARS[rank];
                        pos += BLK.rankIncrement(rank);
                    }
                }
            },
            .brlgraph, .blkgraph => {
                const g = if (opt == .brlgraph)
                    state.graph_brl
                else
                    state.graph_blk;

                var nr_sample_slots = writer.unusedCapacityLen() / BAR_WIDTH;
                if (opt == .brlgraph)
                    nr_sample_slots *= 2;

                const nr_samples = g.mask + 1;
                const n = @min(nr_samples, nr_sample_slots);

                // Skip `nr_samples - n` oldest samples if they can't fit.
                var i = (g.cur + nr_samples - n) & g.mask;
                if (opt == .brlgraph) {
                    for (0..n / 2) |_| {
                        buffer[pos..][0..BAR_WIDTH].* = BRL.rankChar(g.at(i), g.at(i + 1));
                        pos += BAR_WIDTH;
                        i += 2;
                    }
                } else {
                    for (0..n) |_| {
                        const rank = g.at(i);
                        buffer[pos..][0..BAR_WIDTH].* = BLK.BARS[rank];
                        pos += BLK.rankIncrement(rank);
                        i += 1;
                    }
                }
            },
        }
        writer.end = pos;
    }
}
