const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const unt = @import("unit.zig");

const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");

const w_bat = @import("w_bat.zig");
const w_cpu = @import("w_cpu.zig");
const w_dysk = @import("w_dysk.zig");
const w_mem = @import("w_mem.zig");
const w_net = @import("w_net.zig");
const w_read = @import("w_read.zig");
const w_time = @import("w_time.zig");

const builtin = std.builtin;
const enums = std.enums;
const fs = std.fs;
const linux = std.os.linux;
const mem = std.mem;
const meta = std.meta;

// == public types ============================================================

// 1/10th of a second
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
        wopts: unt.NumUnit.WriteOptions,
        flags: Flags,

        const Flags = packed struct(u16) {
            diff: bool,
            persec: bool,
            quiet: bool,
            _: u13,

            pub const default: Flags = .{
                .diff = false,
                .persec = false,
                .quiet = false,
                ._ = 0,
            };
        };

        pub fn initDefault(str: umem.MemSlice(u8), opt: u8) @This() {
            return .{
                .str = str,
                .opt = opt,
                .wopts = .default,
                .flags = .default,
            };
        }
    };
};

pub const Widget = struct {
    id: Id,
    data: Data,
    interval: Interval,
    fg: Color,
    bg: Color,
    format: Format,

    pub fn initDefault(id: Id, data: Data) @This() {
        return .{
            .id = id,
            .data = data,
            .interval = .init(WIDGET_INTERVAL_DEFAULT),
            .fg = .{ .static = .default },
            .bg = .{ .static = .default },
            .format = .{ .parts = .zero, .last_str = .zero },
        };
    }

    const NR_WIDGETS = @typeInfo(Id).@"enum".fields.len;

    pub const Id = enum(u8) {
        TIME,
        MEM,
        CPU,
        DISK,
        NET,
        BAT,
        READ,

        pub const RequiresArg = MakeEnumSubset(Id, &.{
            .TIME, .DISK, .NET, .BAT, .READ,
        });

        pub const ActiveColorSupported = MakeEnumSubset(Id, &.{
            .MEM, .CPU, .DISK, .NET, .BAT,
        });

        pub fn checkCastTo(self: @This(), comptime T: type) ?T {
            return enums.fromInt(T, @intFromEnum(self));
        }
    };

    pub const Data = union {
        TIME: *Time,
        MEM: *Mem,
        CPU: *Cpu,
        DISK: *Disk,
        NET: *Net,
        BAT: *Bat,
        READ: *Read,

        const SIZE_MAX = 64;

        comptime {
            const assert = std.debug.assert;
            assert(@sizeOf(Time) <= SIZE_MAX);
            assert(@sizeOf(Time) <= SIZE_MAX);
            assert(@sizeOf(Mem) <= SIZE_MAX);
            assert(@sizeOf(Cpu) <= SIZE_MAX);
            assert(@sizeOf(Disk) <= SIZE_MAX);
            assert(@sizeOf(Net) <= SIZE_MAX);
            assert(@sizeOf(Bat) <= SIZE_MAX);
            assert(@sizeOf(Read) <= SIZE_MAX);
        }

        pub const Time = struct {
            strf: [STRF_SIZE]u8,

            const STRF_SIZE = 32;

            pub fn init(reg: *umem.Region, arg: []const u8) !*@This() {
                if (arg.len >= STRF_SIZE)
                    log.fatal(&.{"TIME: strftime format too long"});

                const ret = try reg.alloc(@This(), .front);
                @memcpy(ret.strf[0..arg.len], arg);
                ret.strf[arg.len] = 0;
                return ret;
            }

            pub fn getStrf(self: *const @This()) [*:0]const u8 {
                return @ptrCast(&self.strf);
            }
        };

        pub const Mem = struct {
            opt_mask: Masks,

            const Masks = struct {
                pct: OptBit,

                const zero: Masks = .{ .pct = 0 };
            };

            pub fn init(reg: *umem.Region, format: Format, base: [*]const u8) !*@This() {
                const ret = try reg.alloc(@This(), .front);
                var opt_mask: Masks = .zero;
                for (format.parts.get(base)) |*part| {
                    const opt: MemOpt = @enumFromInt(part.opt);
                    const bit = optBit(part.opt);

                    if (opt.checkCastTo(MemOpt.PercentOpts)) |_|
                        opt_mask.pct |= bit;
                }
                ret.opt_mask = opt_mask;
                return ret;
            }
        };

        pub const Cpu = struct {
            opt_mask: Masks,

            const Masks = struct {
                usage: OptBit,
                stats: OptBit,

                const zero: Masks = .{ .usage = 0, .stats = 0 };
            };

            pub fn init(reg: *umem.Region, format: Format, base: [*]const u8) !*@This() {
                const ret = try reg.alloc(@This(), .front);
                var opt_mask: Masks = .zero;
                for (format.parts.get(base)) |*part| {
                    const opt: CpuOpt = @enumFromInt(part.opt);
                    const bit = optBit(part.opt);

                    if (opt.checkCastTo(CpuOpt.UsageOpts)) |_| {
                        opt_mask.usage |= bit;
                    } else if (opt.checkCastTo(CpuOpt.StatsOpts)) |_| {
                        opt_mask.stats |= bit;
                    }
                }
                ret.opt_mask = opt_mask;
                return ret;
            }
        };

        pub const Disk = struct {
            opt_mask: Masks,
            mount_id: u8,
            len: u8,
            mountpoint: [MOUNTPOINT_SIZE]u8,

            const Masks = struct {
                pct: OptBit,
                pct_ino: OptBit,
                size: OptBit,

                const zero: Masks = .{ .pct = 0, .pct_ino = 0, .size = 0 };
            };

            const MOUNTPOINT_SIZE =
                SIZE_MAX - @sizeOf(Masks) - 1 - 1;

            pub fn init(
                reg: *umem.Region,
                arg: []const u8,
                format: Format,
                base: [*]const u8,
            ) !*@This() {
                if (arg.len >= MOUNTPOINT_SIZE)
                    log.fatal(&.{"DISK: mountpoint path too long"});

                const ret = try reg.alloc(@This(), .front);
                ret.mount_id = 0;
                ret.len = @intCast(arg.len);
                @memcpy(ret.mountpoint[0..arg.len], arg);
                ret.mountpoint[arg.len] = 0;
                var opt_mask: Masks = .zero;
                for (format.parts.get(base)) |*part| {
                    const opt: DiskOpt = @enumFromInt(part.opt);
                    const bit = optBit(part.opt);

                    if (opt.checkCastTo(DiskOpt.PercentOpts)) |_| {
                        opt_mask.pct |= bit;
                        if (opt.checkCastTo(DiskOpt.PercentInoOpts)) |_|
                            opt_mask.pct_ino |= bit;
                    } else if (opt.checkCastTo(DiskOpt.SizeOpts)) |_| {
                        opt_mask.size |= bit;
                    }
                }
                ret.opt_mask = opt_mask;
                return ret;
            }

            pub fn getMountpoint(self: *const @This()) [:0]const u8 {
                return self.mountpoint[0..self.len :0];
            }
        };

        pub const Net = struct {
            ifr: linux.ifreq,
            opt_mask: Masks,

            const Masks = struct {
                enabled: Flags,
                string: OptBit,
                netdev: OptBit,
                netdev_size: OptBit,

                const Flags = PackedFlagsFromEnum(NetOpt, OptBit);

                const zero: Masks = .{
                    .enabled = @bitCast(@as(OptBit, 0)),
                    .string = 0,
                    .netdev = 0,
                    .netdev_size = 0,
                };
            };

            pub fn init(
                reg: *umem.Region,
                arg: []const u8,
                format: Format,
                base: [*]const u8,
            ) !*@This() {
                if (arg.len >= linux.IFNAMESIZE)
                    log.fatal(&.{ "NET: interface name too long: ", arg });

                const ret = try reg.alloc(@This(), .front);
                @memset(ret.ifr.ifrn.name[0..], 0);
                @memcpy(ret.ifr.ifrn.name[0..arg.len], arg);

                var opt_mask: Masks = .zero;
                for (format.parts.get(base)) |*part| {
                    const opt: NetOpt = @enumFromInt(part.opt);
                    const bit = optBit(part.opt);

                    if (opt.checkCastTo(NetOpt.StringOpts)) |_| {
                        opt_mask.string |= bit;
                    } else if (opt.checkCastTo(NetOpt.NetDevOpts)) |_| {
                        opt_mask.netdev |= bit;
                        if (opt.checkCastTo(NetOpt.NetDevSizeOpts)) |_|
                            opt_mask.netdev_size |= bit;
                    }
                }
                ret.opt_mask = opt_mask;
                ret.opt_mask.enabled = @bitCast(opt_mask.string | opt_mask.netdev);
                return ret;
            }
        };

        pub const Bat = struct {
            ps_off: u8,
            ps_len: u8,
            path: [PATH_SIZE]u8,

            pub const PATH_SIZE = SIZE_MAX - 1 - 1;
            pub const PS_NAME_SIZE_MAX = 12;

            pub fn init(reg: *umem.Region, arg: []const u8) !*@This() {
                const prefix = "/sys/class/power_supply/";
                const suffix = "/uevent\x00";
                const avail = @min(PATH_SIZE - prefix.len - suffix.len, PS_NAME_SIZE_MAX);
                comptime std.debug.assert(avail == PS_NAME_SIZE_MAX);

                if (arg.len > avail)
                    log.fatal(&.{"BAT: battery name too long"});

                const ret = try reg.alloc(@This(), .front);
                ret.ps_off = prefix.len;
                ret.ps_len = @intCast(arg.len);
                @memcpy(ret.path[0..prefix.len], prefix);
                @memcpy(ret.path[prefix.len..][0..arg.len], arg);
                @memcpy(ret.path[prefix.len + arg.len ..][0..suffix.len], suffix);
                return ret;
            }

            pub fn getPath(self: *const @This()) [*:0]const u8 {
                return @ptrCast(&self.path);
            }

            pub fn getPsName(self: *const @This()) []const u8 {
                return self.path[self.ps_off..][0..self.ps_len];
            }
        };

        pub const Read = struct {
            basename_off: u8,
            basename_len: u8,
            path: [PATH_SIZE]u8,

            const PATH_SIZE = SIZE_MAX - 1 - 1;

            pub fn init(reg: *umem.Region, arg: []const u8) !*@This() {
                const dirname = fs.path.dirname(arg) orelse
                    log.fatal(&.{"READ: path must be absolute"});
                const basename = fs.path.basename(arg);

                if (dirname.len + 1 + basename.len >= PATH_SIZE)
                    log.fatal(&.{"READ: path too long"});

                var path: [PATH_SIZE]u8 = undefined;
                var off = dirname.len;

                @memcpy(path[0..dirname.len], dirname);
                if (dirname.len > 0 and dirname[dirname.len - 1] != '/') {
                    path[dirname.len] = '/';
                    off += 1;
                }
                @memcpy(path[off..][0..basename.len], basename);
                path[off + basename.len] = 0;

                const ret = try reg.alloc(@This(), .front);
                ret.* = .{
                    .basename_off = @intCast(off),
                    .basename_len = @intCast(basename.len),
                    .path = path,
                };
                return ret;
            }

            pub fn getPath(self: *const @This()) [*:0]const u8 {
                return @ptrCast(&self.path);
            }

            pub fn getBasename(self: *const @This()) []const u8 {
                return self.path[self.basename_off..][0..self.basename_len];
            }
        };
    };

    pub const Color = union(enum) {
        active: color.Active,
        static: color.Hex,
    };

    pub fn check(
        self: @This(),
        indirect: anytype,
        base: [*]const u8,
    ) struct { color.Hex, color.Hex } {
        return .{
            switch (self.fg) {
                .active => |active| indirect.checkPairs(active, base),
                .static => |static| static,
            },
            switch (self.bg) {
                .active => |active| indirect.checkPairs(active, base),
                .static => |static| static,
            },
        };
    }

    pub const NoopColorHandler = struct {
        pub fn checkPairs(
            other: *const @This(),
            active: color.Active,
            base: [*]const u8,
        ) color.Hex {
            _ = other;
            _ = active;
            _ = base;
            return .default;
        }
    };
};

pub const TimeOpt = enum(u8) {
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
    arg,

    pub const ColorSupported = enum(u8) {};
};

pub const MemOpt = enum(u8) {
    @"%total",
    @"%free",
    @"%available",
    @"%buffers",
    @"%cached",
    @"%dirty",
    @"%writeback",
    @"%used",

    total,
    free,
    available,
    buffers,
    cached,
    dirty,
    writeback,
    used,

    pub const SIZE_OPTS_OFF = @intFromEnum(MemOpt.total);

    pub const PercentOpts = MakeEnumSubset(@This(), &.{
        .@"%total",  .@"%free",  .@"%available", .@"%buffers",
        .@"%cached", .@"%dirty", .@"%writeback", .@"%used",
    });

    pub const SizeOpts = MakeEnumSubset(@This(), &.{
        .total,  .free,  .available, .buffers,
        .cached, .dirty, .writeback, .used,
    });

    pub const ColorSupported = PercentOpts;

    pub fn checkCastTo(self: @This(), comptime T: type) ?T {
        return enums.fromInt(T, @intFromEnum(self));
    }
};

pub const CpuOpt = enum(u8) {
    @"%all",
    @"%user",
    @"%sys",
    @"%iowait",
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

    pub const STATS_OPTS_OFF = @intFromEnum(CpuOpt.intr);

    pub const UsageOpts = MakeEnumSubset(@This(), &.{
        .@"%all", .@"%user", .@"%sys", .@"%iowait",
        .all,     .user,     .sys,     .iowait,
    });

    pub const StatsOpts = MakeEnumSubset(@This(), &.{
        .intr, .softirq, .blocked, .running, .forks, .ctxt,
    });

    pub const SpecialOpts = MakeEnumSubset(@This(), &.{
        .brlbars, .blkbars,
    });

    pub const ColorSupported = MakeEnumSubset(@This(), &.{
        .@"%all", .@"%user", .@"%sys", .@"%iowait",
        .blocked, .running,  .forks,
    });

    pub fn castTo(self: @This(), comptime T: type) T {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn checkCastTo(self: @This(), comptime T: type) ?T {
        return enums.fromInt(T, @intFromEnum(self));
    }
};

pub const DiskOpt = enum(u8) {
    @"%total",
    @"%free",
    @"%available",
    @"%used",
    @"%ino_total",
    @"%ino_free",
    @"%ino_used",
    total,
    free,
    available,
    used,
    ino_total,
    ino_free,
    ino_used,

    arg,

    // Distance from %total.
    pub const SIZE_OPTS_OFF = @intFromEnum(DiskOpt.total);
    // Distance from %ino_total.
    pub const SI_INO_OPTS_OFF = 7;

    pub const PercentOpts = MakeEnumSubset(@This(), &.{
        .@"%total",     .@"%free",     .@"%available", .@"%used",
        .@"%ino_total", .@"%ino_free", .@"%ino_used",
    });

    pub const PercentInoOpts = MakeEnumSubset(@This(), &.{
        .@"%ino_total", .@"%ino_free", .@"%ino_used",
    });

    pub const SizeOpts = MakeEnumSubset(@This(), &.{
        .total, .free, .available, .used,
    });

    pub const ColorSupported = PercentOpts;

    pub fn checkCastTo(self: @This(), comptime T: type) ?T {
        return enums.fromInt(T, @intFromEnum(self));
    }
};

pub const NetOpt = enum(u8) {
    arg,
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

    pub const NETDEV_OPTS_OFF = @intFromEnum(NetOpt.rx_bytes);

    pub const StringOpts = MakeEnumSubset(@This(), &.{
        .arg, .inet, .flags, .state,
    });

    pub const NetDevOpts = MakeEnumSubset(@This(), &.{
        .rx_bytes, .rx_pkts,  .rx_errs,       .rx_drop,
        .rx_fifo,  .rx_frame, .rx_compressed, .rx_multicast,
        .tx_bytes, .tx_pkts,  .tx_errs,       .tx_drop,
        .tx_fifo,  .tx_colls, .tx_carrier,    .tx_compressed,
    });

    pub const NetDevSizeOpts = MakeEnumSubset(@This(), &.{
        .rx_bytes, .tx_bytes,
    });

    pub const ColorSupported = MakeEnumSubset(@This(), &.{
        .state,
    });

    pub fn castTo(self: @This(), comptime T: type) T {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn checkCastTo(self: @This(), comptime T: type) ?T {
        return enums.fromInt(T, @intFromEnum(self));
    }
};

pub const BatOpt = enum(u8) {
    state,
    @"%fulldesign",
    @"%fullnow",
    arg,

    pub const ColorSupported = MakeEnumSubset(@This(), &.{
        .@"%fulldesign", .@"%fullnow", .state,
    });
};

pub const ReadOpt = enum(u8) {
    arg,
    basename,
    content,
    raw,

    pub const ColorSupported = enum(u8) {};
};

pub fn strWid(str: []const u8) ?Widget.Id {
    inline for (@typeInfo(Widget.Id).@"enum".fields) |field| {
        if (mem.eql(u8, str, field.name))
            return @enumFromInt(field.value);
    }
    return null;
}

const WID_OPT_TYPE = &.{
    TimeOpt, MemOpt, CpuOpt, DiskOpt, NetOpt, BatOpt, ReadOpt,
};

comptime {
    if (Widget.NR_WIDGETS != WID_OPT_TYPE.len)
        @compileError("Adjust WID_OPT_TYPE");
}

// == public ==================================================================

/// Names of options supported by widgets' formats keyed by
/// @intFromEnum(Widget.Tag).
pub const WID__OPT_NAMES: [Widget.NR_WIDGETS][]const [:0]const u8 = blk: {
    var w: [Widget.NR_WIDGETS][]const [:0]const u8 = undefined;
    for (WID_OPT_TYPE, 0..) |T, i| {
        w[i] = meta.fieldNames(T);
    }
    break :blk w;
};

/// Particular widgets' format option state of color support keyed by
/// @intFromEnum(Widget.Tag).
pub const WID__OPTS_SUPPORTING_COLOR: [Widget.NR_WIDGETS][]const bool = blk: {
    var w: [Widget.NR_WIDGETS][]const bool = undefined;
    for (WID_OPT_TYPE, 0..) |T, i| {
        const len = @typeInfo(T).@"enum".fields.len;
        var supporting_color: [len]bool = @splat(false);
        for (enums.values(T.ColorSupported)) |v| {
            supporting_color[@intFromEnum(v)] = true;
        }
        const final = supporting_color;
        w[i] = &final;
    }
    break :blk w;
};

/// Default widget refresh interval of 5 seconds.
pub const WIDGET_INTERVAL_DEFAULT = 50;

/// Maximum widget refresh interval (refresh once and forget).
pub const WIDGET_INTERVAL_MAX: DeciSec = (1 << 31) - 1;

/// Individual widget maximum buffer size.
pub const WIDGET_BUF_MAX = 128;

pub fn writeWidgetBeg(writer: *uio.Writer, fg: color.Hex, bg: color.Hex) void {
    if (WIDGET_BUF_MAX < 64)
        @compileError("typ.WIDGET_BUF_MAX < 64");

    const dst = writer.buffer[writer.end..];
    switch (fg.use | @shlExact(bg.use, 1)) {
        0 => {
            const s = "{\"full_text\":\"";
            dst[0..16].* = (s ++ .{ undefined, undefined }).*;
            writer.end += s.len;
        },
        1 => {
            const s =
                \\{"color":"#XXXXXX","full_text":"
            ;
            dst[0..32].* = s.*;
            dst[11..17].* = fg.hex;
            writer.end += s.len;
        },
        2 => {
            const s =
                \\{"background":"#XXXXXX","full_text":"
            ;
            dst[0..37].* = s.*;
            dst[16..22].* = bg.hex;
            writer.end += s.len;
        },
        3 => {
            const s =
                \\{"color":"#XXXXXX","background":"#XXXXXX","full_text":"
            ;
            dst[0..55].* = s.*;
            dst[11..17].* = fg.hex;
            dst[34..40].* = bg.hex;
            writer.end += s.len;
        },
        else => unreachable,
    }
}

pub fn writeWidgetEnd(writer: *uio.Writer) []const u8 {
    const endstr = "\"},";
    const cap = writer.unusedCapacityLen();
    const buffer = writer.buffer;
    const end = writer.end;

    if (endstr.len <= cap) {
        @branchHint(.likely);
        buffer[end..][0..3].* = endstr.*;
        writer.end = end + 3;
        return buffer[0 .. end + 3];
    }

    buffer[buffer.len - 6 ..][0..6].* = ("…" ++ endstr).*;
    writer.end = buffer.len;
    return buffer;
}

pub fn writeWidget(
    writer: *uio.Writer,
    fg: color.Hex,
    bg: color.Hex,
    data: []const []const u8,
) void {
    writeWidgetBeg(writer, fg, bg);
    for (data) |s| uio.writeStr(writer, s);
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
    // Might generate a cmov if there are spare registers available.
    var value = new;
    if (flags.diff)
        value -= old;
    if (flags.persec) {
        if (!flags.diff) unreachable;
        const span: UDeciSec = @intCast(interval.set - interval.now);
        value = value * 10 / span;
    }
    return value;
}

pub inline fn calcWithOverflow(
    new: u64,
    old: u64,
    interval: Interval,
    flags: Format.Part.Flags,
) struct { u64, bool } {
    var value, var of: u8 = .{ new, 0 };
    if (flags.diff) {
        value, of = @subWithOverflow(value, old);
        if (of != 0)
            value = 0 -% value;
        if (flags.persec) {
            const span: UDeciSec = @intCast(interval.set - interval.now);
            value = value * 10 / span;
        }
    }
    return .{ value, of != 0 };
}

// == meta functions ==========================================================

pub fn MakeEnumSubset(comptime E: type, comptime new_values: []const E) type {
    const E_enum = @typeInfo(E).@"enum";

    if (new_values.len == 0)
        @compileError("Attempted to create an `enum {}`");

    if (new_values.len > E_enum.fields.len)
        @compileError("Provided at least one duplicate enum field");

    var new_val_max = 0;
    var result: [new_values.len]builtin.Type.EnumField = undefined;
    for (new_values, 0..) |new_value, i| {
        const v = @intFromEnum(new_value);
        result[i] = .{ .name = @tagName(new_value), .value = v };
        new_val_max = @max(new_val_max, v);
    }
    return @Type(.{
        .@"enum" = .{
            .tag_type = E_enum.tag_type,
            .fields = &result,
            .decls = &.{},
            .is_exhaustive = E_enum.is_exhaustive,
        },
    });
}

// This is useful if wanting to use enum fields as flags. The order of
// flags in the backing integer changes if enum's field positions change,
// lowering the maintenance burden and helping avoid subtle bugs at the
// cost of discoverability of the resulting struct definition. Enum field
// values must start at 0 and increment linearly.
//
// Flags may be initialized as follows:
//
//     const Flags = PackedFlagsFromEnum(Enum, u32);
//     var w: u32 = 0;
//     for (enum_values) |value|
//         w |= @as(u32, 1) << value;
//     const flags: Flags = @bitCast(w);
//
// To see the "definition" of the generated struct:
//
//     comptime {
//         for (@typeInfo(Flags).@"struct".fields) |field|
//             @compileLog(field.type, field.name);
//     }
//
pub fn PackedFlagsFromEnum(comptime E: type, comptime BackingInt: type) type {
    const E_enum = @typeInfo(E).@"enum";
    const BI_int = @typeInfo(BackingInt).int;

    if (E_enum.fields.len == 0)
        @compileError("Provided an empty enum");
    if (BI_int.signedness != .unsigned)
        @compileError("Unsigned please");
    if (BI_int.bits == 0 or (BI_int.bits & (BI_int.bits - 1)) != 0)
        @compileError("No weird sizes please");
    if (BI_int.bits < E_enum.fields.len)
        @compileError("Backing integer cannot represent all enum fields");

    const pad_bits = BI_int.bits - E_enum.fields.len;
    const pad_type = meta.Int(.unsigned, pad_bits);

    var nr_struct_fields = E_enum.fields.len;
    if (pad_bits > 0) {
        nr_struct_fields += 1;
    }
    var struct_fields: [nr_struct_fields]builtin.Type.StructField = undefined;
    for (E_enum.fields, 0..) |field, i| {
        if (field.value != i)
            @compileError("Enum field values must start at 0 and increment linearly");
        struct_fields[i] = .{
            .alignment = 0,
            .default_value_ptr = null,
            .is_comptime = false,
            .name = field.name,
            .type = bool,
        };
    }
    if (pad_bits > 0) {
        struct_fields[nr_struct_fields - 1] = .{
            .alignment = 0,
            .default_value_ptr = null,
            .is_comptime = false,
            .name = "_",
            .type = pad_type,
        };
    }
    return @Type(.{
        .@"struct" = .{
            .backing_integer = BackingInt,
            .decls = &.{},
            .fields = &struct_fields,
            .is_tuple = false,
            .layout = .@"packed",
        },
    });
}
