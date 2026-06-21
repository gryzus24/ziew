const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const unt = @import("unit.zig");

const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");

const enums = std.enums;
const fs = std.fs;
const linux = std.os.linux;

// == public types ============================================================

// `Widget.Id` or `OptTypes` hash.
pub const WidOptHash = u32;

// 1/10th of a second.
pub const DeciSec = i32;
pub const UDeciSec = u32;

pub const OptBit = u32;

pub const Interval = struct {
    set: DeciSec,
    now: DeciSec,

    pub fn init(set: DeciSec) @This() {
        return .{ .set = set, .now = 0 };
    }
};

pub const Format = struct {
    parts: umem.MemSlice(Part),
    last_str: umem.MemSlice(u8),

    pub const Part = struct {
        str: umem.MemSlice(u8),
        opt: u8,
        flags: Flags,
        wopts: unt.NumUnit.WriteOptions,

        comptime {
            std.debug.assert(@sizeOf(Part) == 8);
        }

        const Flags = packed struct(u8) {
            pct: bool,
            diff: bool,
            persec: bool,
            _: u5 = undefined,

            pub const default: Flags = .{
                .pct = false,
                .diff = false,
                .persec = false,
            };
        };

        pub fn initDefault(str: umem.MemSlice(u8), opt: u8) @This() {
            return .{
                .str = str,
                .opt = opt,
                .flags = .default,
                .wopts = .default,
            };
        }
    };
};

pub const Widget = struct {
    id: Id,
    data: Off,
    fg: Color,
    bg: Color,
    format: Format,

    const Off = usize;

    pub fn initDefault(id: Id, data: Off) Widget {
        return .{
            .id = id,
            .data = data,
            .fg = .{ .static = .empty },
            .bg = .{ .static = .empty },
            .format = .{ .parts = .zero, .last_str = .zero },
        };
    }

    pub fn getInterval(self: *const @This(), base: [*]u8) *Interval {
        const ptr: *WidgetData(null) = @ptrCast(@alignCast(base[self.data..]));
        return &ptr.interval;
    }

    pub fn readInterval(self: *const @This(), base: [*]const u8) Interval {
        const ptr: *const WidgetData(null) = @ptrCast(@alignCast(base[self.data..]));
        return ptr.interval;
    }

    pub fn getData(
        self: *const @This(),
        comptime wid: Widget.Id,
        base: [*]u8,
    ) *Data(wid) {
        return @ptrCast(@alignCast(base[self.data + @sizeOf(WidgetData(wid)) ..]));
    }

    pub fn getDataConst(
        self: *const @This(),
        comptime wid: Widget.Id,
        base: [*]const u8,
    ) *const Data(wid) {
        return @ptrCast(@alignCast(base[self.data + @sizeOf(WidgetData(wid)) ..]));
    }

    pub const NR_WIDGETS = enumFields(Id).len;

    pub const Id = enum(u8) {
        TIME,
        MEM,
        CPU,
        DISK,
        NET,
        BAT,
        READ,

        pub const ArgRequired = EnumSubset(Id, &.{
            .TIME, .DISK, .NET, .BAT, .READ,
        });

        pub const ActiveColorSupported = EnumSubset(Id, &.{
            .MEM, .CPU, .DISK, .NET, .BAT,
        });

        pub inline fn checkCastTo(self: @This(), comptime E: type) ?E {
            const m = MaskFromEnum(E);
            comptime std.debug.assert(m <= ~@as(u32, 0));
            const bit = @as(u32, 1) << @intCast(@intFromEnum(self));
            return if (bit & m != 0) @enumFromInt(@intFromEnum(self)) else null;
        }
    };

    pub const Color = union(enum) {
        active: color.Active,
        static: color.Hex,
    };

    pub fn check(self: *const @This(), indirect: anytype, base: [*]const u8) [2]color.Hex {
        return .{
            switch (self.fg) {
                .active => |*active| indirect.checkPairs(
                    active.opt,
                    active.pct,
                    active.pairs.get(base),
                ),
                .static => |static| static,
            },
            switch (self.bg) {
                .active => |*active| indirect.checkPairs(
                    active.opt,
                    active.pct,
                    active.pairs.get(base),
                ),
                .static => |static| static,
            },
        };
    }

    pub fn colorForceStatic(self: *const @This()) [2]color.Hex {
        return .{
            switch (self.fg) {
                .active => .empty,
                .static => |static| static,
            },
            switch (self.bg) {
                .active => .empty,
                .static => |static| static,
            },
        };
    }
};

fn Data(comptime wid: Widget.Id) type {
    return switch (wid) {
        .TIME => struct {
            strf: FlexField([*:0]const u8),

            pub fn init(reg: *umem.Region, arg: []const u8) !void {
                _ = try reg.writeStrZ(arg, .front);
            }
        },
        .MEM, .CPU => void,
        .DISK => struct {
            mount_id: u8,
            len: u8,
            mountpoint: FlexField([*:0]const u8),

            pub fn init(reg: *umem.Region, arg: []const u8) !void {
                if (arg.len > 0xff)
                    log.fatal(&.{"DISK: mountpoint path too long"});

                (try reg.alloc(@This(), .front)).* = .{
                    .mount_id = 0,
                    .len = @intCast(arg.len),
                    .mountpoint = undefined,
                };
                _ = try reg.writeStrZ(arg, .front);
            }

            pub fn getMountpoint(self: *const @This()) [:0]const u8 {
                return self.mountpoint.get()[0..self.len :0];
            }
        },
        .NET => struct {
            ifr: linux.ifreq,
            opt_enabled: Mask,

            const Mask = struct {
                bits: OptBit,

                pub const zero: Mask = .{ .bits = 0 };

                pub fn inet(self: @This()) bool {
                    return self.bits & optBit(@intFromEnum(Opts.Net.inet)) != 0;
                }
                pub fn flags(self: @This()) bool {
                    return self.bits & optBit(@intFromEnum(Opts.Net.flags)) != 0;
                }
                pub fn state(self: @This()) bool {
                    return self.bits & optBit(@intFromEnum(Opts.Net.state)) != 0;
                }
            };

            pub fn init(reg: *umem.Region, arg: []const u8) !void {
                if (arg.len >= linux.IFNAMESIZE)
                    log.fatal(&.{ "NET: interface name too long: ", arg });

                var ptr = try reg.alloc(@This(), .front);
                @memset(ptr.ifr.ifrn.name[0..], 0);
                @memcpy(ptr.ifr.ifrn.name[0..arg.len], arg);
                ptr.opt_enabled = .zero;
            }

            pub fn gatherOptEnabled(
                self: *@This(),
                widget: *const Widget,
                base: [*]const u8,
            ) void {
                var enabled: Mask = .zero;
                var it: OptIterator = .init(widget, base);
                while (it.next()) |e| enabled.bits |= optBit(e.opt);
                self.opt_enabled = enabled;
            }
        },
        .BAT => struct {
            ps_off: u8,
            ps_len: u8,
            path: FlexField([*:0]const u8),

            const prefix = "/sys/class/power_supply/";
            const suffix = "/uevent\x00";

            pub const PS_NAME_SIZE_MAX = 8;

            pub fn init(reg: *umem.Region, arg: []const u8) !void {
                if (arg.len > PS_NAME_SIZE_MAX)
                    log.fatal(&.{"BAT: battery name too long"});

                (try reg.alloc(@This(), .front)).* = .{
                    .ps_off = prefix.len,
                    .ps_len = @intCast(arg.len),
                    .path = undefined,
                };
                const path = try reg.allocMany(u8, prefix.len + arg.len + suffix.len, .front);
                uio.memcpyMany(path, .{ prefix, arg, suffix });
            }

            pub fn getPsName(self: *const @This()) []const u8 {
                return self.path.get()[self.ps_off..][0..self.ps_len];
            }
        },
        .READ => struct {
            basename_off: u8,
            basename_len: u8,
            path: FlexField([*:0]const u8),

            pub fn init(reg: *umem.Region, arg: []const u8) !void {
                const dirname = fs.path.dirname(arg) orelse
                    log.fatal(&.{"READ: path must be absolute"});
                const basename = fs.path.basename(arg);

                const path_len = dirname.len + 1 + basename.len;
                if (path_len > 0xff)
                    log.fatal(&.{"READ: path too long"});

                (try reg.alloc(@This(), .front)).* = .{
                    .basename_off = @intCast(dirname.len + 1),
                    .basename_len = @intCast(basename.len),
                    .path = undefined,
                };
                const path = try reg.allocMany(u8, path_len + 1, .front);
                uio.memcpyMany(path, .{ dirname, "/", basename, "\x00" });
            }

            pub fn getBasename(self: *const @This()) []const u8 {
                return self.path.get()[self.basename_off..][0..self.basename_len];
            }
        },
    };
}

pub fn WidgetData(comptime wid: ?Widget.Id) type {
    const alignment = blk: {
        var w = 0;
        for (enums.values(Widget.Id)) |v|
            w = @max(w, @alignOf(Data(v)));
        break :blk w;
    };
    if (wid) |ok| {
        return struct {
            interval: Interval align(alignment),
            data: void,

            pub fn init(reg: *umem.Region, interval: Interval, arg: []const u8) !Widget.Off {
                const sp = reg.save(@This(), .front);
                (try reg.alloc(@This(), .front)).* = .{
                    .interval = interval,
                    .data = undefined,
                };
                try Data(ok).init(reg, arg);
                return sp.off;
            }
        };
    } else {
        return struct {
            interval: Interval align(alignment),

            pub fn init(reg: *umem.Region, interval: Interval) !Widget.Off {
                const sp = reg.save(@This(), .front);
                (try reg.alloc(@This(), .front)).* = .{ .interval = interval };
                return sp.off;
            }
        };
    }
}

pub const Opts = struct {
    pub const Time = enum(u8) {
        time,
        @"1",
        @"2",
        @"3",
        @"4",
        @"5",
        @"6",
        @"7",
        @"8",
        @"9",

        pub const PctPrefix = enum(u8) {};
        pub const ColorPct = enum(u8) {};
        pub const ColorBare = enum(u8) {};
    };

    pub const Mem = enum(u8) {
        total,
        free,
        available,
        buffers,
        cached,
        dirty,
        writeback,
        used,

        pub const PctPrefix = @This();
        pub const ColorPct = PctPrefix;
        pub const ColorBare = enum(u8) {};
    };

    pub const Cpu = enum(u8) {
        all,
        user,
        sys,
        iowait,

        intr,
        softirq,
        blocked,
        running,
        forks,
        ctxt,

        brlbars,
        blkbars,
        brlgraph,
        blkgraph,

        pub const STATS_OFF = @intFromEnum(Cpu.intr);

        pub const Usage = EnumSubset(@This(), &.{
            .all, .user, .sys, .iowait,
        });

        pub const Stats = EnumSubset(@This(), &.{
            .intr, .softirq, .blocked, .running, .forks, .ctxt,
        });

        pub const Special = EnumSubset(@This(), &.{
            .brlbars, .blkbars, .brlgraph, .blkgraph,
        });

        pub const PctPrefix = Usage;
        pub const ColorPct = PctPrefix;
        pub const ColorBare = EnumUnion(@This(), Usage, Stats);
        pub const ColorSupported = EnumUnion(@This(), ColorPct, ColorBare);

        pub const USAGE_MASK = MaskFromEnum(Usage);
        pub const STATS_MASK = MaskFromEnum(Stats);
    };

    pub const Disk = enum(u8) {
        total,
        free,
        available,
        used,
        ino_total,
        ino_free,
        ino_used,

        pub const Ino = EnumSubset(@This(), &.{
            .ino_total, .ino_free, .ino_used,
        });

        pub const PctPrefix = @This();
        pub const ColorPct = PctPrefix;
        pub const ColorBare = enum(u8) {};

        pub const INO_MASK = MaskFromEnum(Ino);
    };

    pub const Net = enum(u8) {
        inet,
        flags,
        state,

        rx_bytes,
        rx_pkts,
        rx_errs,
        rx_drop,
        rx_fifo,
        rx_frame,
        rx_compressed,
        rx_multicast,
        tx_bytes,
        tx_pkts,
        tx_errs,
        tx_drop,
        tx_fifo,
        tx_colls,
        tx_carrier,
        tx_compressed,

        pub const NETDEV_OFF = @intFromEnum(Net.rx_bytes);

        pub const String = EnumSubset(@This(), &.{
            .inet, .flags, .state,
        });

        pub const NetDev = EnumSubset(@This(), &.{
            .rx_bytes, .rx_pkts,  .rx_errs,       .rx_drop,
            .rx_fifo,  .rx_frame, .rx_compressed, .rx_multicast,
            .tx_bytes, .tx_pkts,  .tx_errs,       .tx_drop,
            .tx_fifo,  .tx_colls, .tx_carrier,    .tx_compressed,
        });

        pub const NetDevSize = EnumSubset(@This(), &.{
            .rx_bytes, .tx_bytes,
        });

        pub const PctPrefix = enum(u8) {};
        pub const ColorPct = enum(u8) {};
        pub const ColorBare = EnumSubset(@This(), &.{
            .state,
        });

        pub const STRING_MASK = MaskFromEnum(String);
        pub const NETDEV_MASK = MaskFromEnum(NetDev);
        pub const NETDEV_SIZE_MASK = MaskFromEnum(NetDevSize);
    };

    pub const Bat = enum(u8) {
        state,
        fulldesign,
        fullnow,

        pub const PctPrefix = EnumSubset(@This(), &.{
            .fulldesign,
            .fullnow,
        });
        pub const ColorPct = PctPrefix;
        pub const ColorBare = EnumSubset(@This(), &.{
            .state,
        });
        pub const ColorSupported = EnumUnion(@This(), ColorPct, ColorBare);
    };

    pub const Read = enum(u8) {
        basename,
        content,
        raw,

        pub const PctPrefix = enum(u8) {};
        pub const ColorBare = enum(u8) {};
        pub const ColorPct = enum(u8) {};
    };
};

const OptTypes = &.{
    Opts.Time, Opts.Mem, Opts.Cpu,  Opts.Disk,
    Opts.Net,  Opts.Bat, Opts.Read,
};

comptime {
    if (Widget.NR_WIDGETS != OptTypes.len)
        @compileError("Adjust OptTypes");
}

fn makeHashes(comptime E: type) []const WidOptHash {
    @setEvalBranchQuota(2000);
    const fields = enumFields(E);
    var hashes: [fields.len]WidOptHash = undefined;
    for (fields, 0..) |field, i|
        hashes[i] = widOptHash(field.name);
    for (fields, hashes, 1..) |field, hash, i| {
        for (fields[i..], hashes[i..]) |other, other_hash| {
            if (hash == other_hash)
                @compileError("collision: " ++ field.name ++ "=" ++ other.name);
        }
    }
    const final = hashes;
    return &final;
}

// == public ==================================================================

// Iterates over each option referenced by a Widget in order:
//   fg, bg, parts[0], parts[1], ... etc.
pub const OptIterator = struct {
    fg: Widget.Color,
    bg: Widget.Color,
    parts: []const Format.Part,
    i: isize,

    const Item = struct {
        opt: u8,
        pct: bool,
        width: u3,
    };

    pub fn init(widget: *const Widget, base: [*]const u8) @This() {
        return .{
            .fg = widget.fg,
            .bg = widget.bg,
            .parts = widget.format.parts.get(base),
            .i = -2,
        };
    }

    pub fn next(self: *@This()) ?Item {
        if (self.i == -2) {
            self.i += 1;
            switch (self.fg) {
                .active => |a| return .{ .opt = a.opt, .pct = a.pct, .width = 0 },
                .static => {},
            }
        }
        if (self.i == -1) {
            self.i += 1;
            switch (self.bg) {
                .active => |a| return .{ .opt = a.opt, .pct = a.pct, .width = 0 },
                .static => {},
            }
        }
        if (self.i < self.parts.len) {
            const p = &self.parts[@intCast(self.i)];
            self.i += 1;
            return .{ .opt = p.opt, .pct = p.flags.pct, .width = p.wopts.width };
        }
        return null;
    }
};

pub fn widOptHash(str: []const u8) WidOptHash {
    var r: WidOptHash = 5381;
    for (str) |c| {
        r *%= 33;
        r +%= c;
    }
    return r;
}

pub fn strWid(str: []const u8) ?Widget.Id {
    const hash = widOptHash(str);
    for (comptime makeHashes(Widget.Id), 0..) |wid_hash, i| {
        if (hash == wid_hash)
            return @enumFromInt(i);
    }
    return null;
}

pub const WID__OPTION_HASHES: [Widget.NR_WIDGETS][]const WidOptHash = blk: {
    var w: [Widget.NR_WIDGETS][]const WidOptHash = undefined;
    for (OptTypes, 0..) |T, i| w[i] = makeHashes(T);
    break :blk w;
};

pub const WID__OPTIONS_PCT_PREFIX_SUPPORTED: [Widget.NR_WIDGETS][]const bool = blk: {
    var w: [Widget.NR_WIDGETS][]const bool = undefined;
    for (OptTypes, 0..) |T, i| {
        var support: [enumFields(T).len]bool = @splat(false);
        for (enums.values(T.PctPrefix)) |v|
            support[@intFromEnum(v)] = true;
        const final = support;
        w[i] = &final;
    }
    break :blk w;
};

const OptColorSupport = struct {
    bare: bool,
    pct: bool,

    const none: OptColorSupport = .{ .bare = false, .pct = false };
};

pub const WID__OPTIONS_COLOR_SUPPORT: [Widget.NR_WIDGETS][]const OptColorSupport = blk: {
    var w: [Widget.NR_WIDGETS][]const OptColorSupport = undefined;
    for (OptTypes, 0..) |T, i| {
        var support: [enumFields(T).len]OptColorSupport = @splat(.none);
        for (enums.values(T.ColorBare)) |v|
            support[@intFromEnum(v)].bare = true;
        for (enums.values(T.ColorPct)) |v|
            support[@intFromEnum(v)].pct = true;
        const final = support;
        w[i] = &final;
    }
    break :blk w;
};

/// Default widget refresh interval of 5 seconds.
pub const WIDGET_INTERVAL_DEFAULT = 50;

/// Maximum widget refresh interval (refresh once and forget).
pub const WIDGET_INTERVAL_MAX: DeciSec = (1 << 31) - 1;

/// Space reserved for the widget end marker.
pub const WIDGET_BUF_TAIL = 6;

/// Individual widget writable buffer space.
pub const WIDGET_BUF_WRITABLE = 192 - WIDGET_BUF_TAIL;

/// Individual widget buffer size.
pub const WIDGET_BUF_MAX = WIDGET_BUF_WRITABLE + WIDGET_BUF_TAIL;

pub fn writeWidgetBeg(writer: *uio.Writer, fg: color.Hex, bg: color.Hex) void {
    comptime std.debug.assert(WIDGET_BUF_WRITABLE >= 64);

    const headers: [4][]const u8 = .{
        \\{"full_text":"
        [0..],
        \\{"color":"#XXXXXX","full_text":"
        [0..],
        \\{"background":"#XXXXXX","full_text":"
        [0..],
        \\{"color":"#XXXXXX","background":"#XXXXXX","full_text":"
        [0..],
    };

    const dst = writer.buffer[writer.end..];
    switch (@intFromEnum(fg.tag) | @intFromEnum(bg.tag)) {
        0 => {
            const s = headers[0];
            dst[0..16].* = (s ++ .{ undefined, undefined }).*;
            writer.end += s.len;
        },
        1 => {
            const s = headers[1];
            dst[0..32].* = s[0..].*;
            dst[11..17].* = fg.hex;
            writer.end += s.len;
        },
        2 => {
            const s = headers[2];
            dst[0..40].* = (s ++ .{ undefined, undefined, undefined }).*;
            dst[16..22].* = bg.hex;
            writer.end += s.len;
        },
        3 => {
            const s = headers[3];
            dst[0..56].* = (s ++ .{undefined}).*;
            dst[11..17].* = fg.hex;
            dst[34..40].* = bg.hex;
            writer.end += s.len;
        },
        else => unreachable,
    }
}

pub fn writeWidgetEnd(buffer: []u8, end: usize) []const u8 {
    const END_MARKER = "\"},";
    if (end < WIDGET_BUF_WRITABLE) {
        @branchHint(.likely);
        buffer[end..][0..3].* = END_MARKER.*;
        return buffer[0 .. end + 3];
    }
    buffer[end..][0..WIDGET_BUF_TAIL].* = ("…" ++ END_MARKER).*;
    return buffer[0 .. end + WIDGET_BUF_TAIL];
}

pub fn optBit(opt: u8) OptBit {
    return @as(OptBit, 1) << @intCast(opt);
}

pub inline fn calc(
    new: u64,
    old: u64,
    interval: Interval,
    flags: Format.Part.Flags,
) u64 {
    var r = new;
    if (flags.diff)
        r -= old;
    if (flags.persec) {
        if (!flags.diff) unreachable;
        const span: UDeciSec = @intCast(interval.set - interval.now);
        r = r * 10 / span;
    }
    return r;
}

pub inline fn calcWithOverflow(
    new: u64,
    old: u64,
    interval: Interval,
    flags: Format.Part.Flags,
) struct { u64, bool } {
    const d: i64 = @bitCast(new -% old);
    var r, var neg = .{ @abs(d), d < 0 };
    if (!flags.diff)
        r, neg = .{ new, false };
    if (flags.persec) {
        if (!flags.diff) unreachable;
        const span: UDeciSec = @intCast(interval.set - interval.now);
        r = r * 10 / span;
    }
    return .{ r, neg };
}

pub inline fn currPrev(
    comptime T: type,
    items: *[2]T,
    i: usize,
) struct { *T, *T } {
    return .{ &items[i], &items[i ^ 1] };
}

// Yet again, make a const copy of this function to avoid the @constCast.
// I couldn't find anything regarding "perfect forwarding" in Zig to make
// this kind of function work without duplication and play well with ZLS.
pub inline fn constCurrPrev(
    comptime T: type,
    items: *const [2]T,
    i: usize,
) struct { *const T, *const T } {
    return .{ &items[i], &items[i ^ 1] };
}

pub fn allocConfigParserMem(reg: *umem.Region) struct { []u8, []align(16) u8 } {
    const filebuf = reg.allocMany(u8, 2048, .back) catch unreachable;
    const scratch: []align(16) u8 =
        @ptrCast(reg.allocMany(u128, 512 / 16, .back) catch unreachable);
    return .{ filebuf, scratch };
}

// == meta functions ==========================================================

pub fn enumFields(comptime E: type) []const std.builtin.Type.EnumField {
    return @typeInfo(E).@"enum".fields;
}

pub fn EnumSubset(comptime E: type, comptime fields: []const E) type {
    const E_enum = @typeInfo(E).@"enum";

    if (!E_enum.is_exhaustive)
        @compileError("Provided enum must be exhaustive");
    if (fields.len == 0)
        @compileError("Attempted to create an empty enum");
    if (fields.len > E_enum.fields.len)
        @compileError("Provided at least one duplicate enum field");

    var names: [fields.len][]const u8 = undefined;
    var values: [fields.len]E_enum.tag_type = undefined;

    for (fields, 0..) |field, i| {
        names[i], values[i] = .{ @tagName(field), @intFromEnum(field) };
    }
    return @Enum(E_enum.tag_type, .exhaustive, &names, &values);
}

pub fn EnumUnion(comptime E: type, comptime A: type, comptime B: type) type {
    const E_enum = @typeInfo(E).@"enum";
    const A_enum = @typeInfo(A).@"enum";
    const B_enum = @typeInfo(B).@"enum";

    if (!E_enum.is_exhaustive or !A_enum.is_exhaustive or !B_enum.is_exhaustive)
        @compileError("Provided enums must be exhaustive");
    if (A_enum.fields.len == 0 or B_enum.fields.len == 0)
        @compileError("One of provided enums is empty");
    if (A_enum.fields.len > E_enum.fields.len or B_enum.fields.len > E_enum.fields.len)
        @compileError("Provided at least one duplicate enum field");

    var a, var b = .{ 0, 0 };
    for (A_enum.fields) |field| a |= 1 << field.value;
    for (B_enum.fields) |field| b |= 1 << field.value;

    const mask: u64 = a | b;
    const size = @popCount(mask);

    var names: [size][]const u8 = undefined;
    var values: [size]E_enum.tag_type = undefined;

    var i, var m = .{ 0, mask };
    while (m != 0) : (i += 1) {
        const lsb = m & (~m + 1);
        const bit = @ctz(m);
        names[i], values[i] = .{ @tagName(@as(E, @enumFromInt(bit))), bit };
        m ^= lsb;
    }
    return @Enum(E_enum.tag_type, .exhaustive, &names, &values);
}

pub fn MaskFromEnum(comptime E: type) comptime_int {
    var mask = 0;
    for (enumFields(E)) |field| {
        mask |= 1 << field.value;
    }
    if (mask == 0) {
        @compileError("Provided an empty enum");
    }
    return mask;
}

pub fn FlexField(comptime T: type) type {
    const Ptr = @typeInfo(T).pointer;
    if (Ptr.is_const) {
        return struct {
            pub fn get(self: *const @This()) T {
                return @ptrCast(self);
            }
        };
    } else {
        const ConstT = @Pointer(
            Ptr.size,
            .{
                .@"const" = true,
                .@"volatile" = Ptr.is_volatile,
                .@"allowzero" = Ptr.is_allowzero,
                .@"addrspace" = Ptr.address_space,
                .@"align" = Ptr.alignment,
            },
            Ptr.child,
            Ptr.sentinel(),
        );
        return struct {
            pub fn get(self: *const @This()) ConstT {
                return @ptrCast(self);
            }
            pub fn getMutable(self: *@This()) T {
                return @ptrCast(self);
            }
        };
    }
}
