const cfg = @import("config.zig");
const color = @import("color.zig");
const m = @import("memory.zig");
const std = @import("std");
const unt = @import("unit.zig");
const utl = @import("util.zig");
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
const math = std.math;
const mem = std.mem;
const meta = std.meta;

// == public types ============================================================

// 1/10th of a second
pub const DeciSec = u64;

pub const Format = struct {
    part_opts: []Part = &.{},
    part_last: []const u8 = &.{},

    pub const Part = struct {
        str: []const u8,
        opt: u8 = 0,
        flags: Flags = .{},
        wopts: unt.NumUnit.WriteOptions = .{},

        pub const Flags = packed struct {
            diff: bool = false,
            quiet: bool = false,
        };
    };
};

pub const Widget = struct {
    wid: Id,
    interval: DeciSec = WIDGET_INTERVAL_DEFAULT,

    pub const Id = union(Tag) {
        TIME: *TimeData,
        MEM: *MemData,
        CPU: *CpuData,
        DISK: *DiskData,
        NET: *NetData,
        BAT: *BatData,
        READ: *ReadData,

        const Tag = enum { TIME, MEM, CPU, DISK, NET, BAT, READ };

        const NR_WIDGETS = @typeInfo(Tag).@"enum".fields.len;

        pub const TimeData = struct {
            format: [:0]const u8,
            fg: color.Hex = .{},
            bg: color.Hex = .{},

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= STRFTIME_FORMAT_BUF_SIZE_MAX)
                    utl.fatal(&.{"TIME: strftime format too long"});

                const ret = try reg.frontAlloc(@This());

                ret.* = .{ .format = try reg.frontWriteStrZ(arg) };
                return ret;
            }
        };

        pub const MemData = struct {
            format: Format = .{},
            fg: color.Color = .nocolor,
            bg: color.Color = .nocolor,

            pub fn init(reg: *m.Region) !*@This() {
                const ret = try reg.frontAlloc(@This());
                ret.* = .{};
                return ret;
            }
        };

        pub const CpuData = struct {
            format: Format = .{},
            fg: color.Color = .nocolor,
            bg: color.Color = .nocolor,

            pub fn init(reg: *m.Region) !*@This() {
                const ret = try reg.frontAlloc(@This());
                ret.* = .{};
                return ret;
            }
        };

        pub const DiskData = struct {
            mountpoint: [:0]const u8,
            format: Format = .{},
            fg: color.Color = .nocolor,
            bg: color.Color = .nocolor,

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= WIDGET_BUF_MAX)
                    utl.fatal(&.{"DISK: mountpoint path too long"});

                const retptr = try reg.frontAlloc(@This());

                retptr.* = .{ .mountpoint = try reg.frontWriteStrZ(arg) };
                return retptr;
            }
        };

        pub const NetData = struct {
            ifr: linux.ifreq,
            format: Format = .{},
            fg: color.Color = .nocolor,
            bg: color.Color = .nocolor,

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                var ifr: linux.ifreq = undefined;
                if (arg.len >= ifr.ifrn.name.len)
                    utl.fatal(&.{ "NET: interface name too long: ", arg });

                const retptr = try reg.frontAlloc(@This());

                @memset(ifr.ifrn.name[0..], 0);
                @memcpy(ifr.ifrn.name[0..arg.len], arg);
                retptr.* = .{ .ifr = ifr };

                return retptr;
            }
        };

        pub const BatData = struct {
            ps_name: []const u8,
            path: [*:0]const u8,
            format: Format = .{},
            fg: color.Color = .nocolor,
            bg: color.Color = .nocolor,

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= 32) utl.fatal(&.{"BAT: battery name too long"});

                const retptr = try reg.frontAlloc(@This());

                var n: usize = 0;
                const base = reg.frontSave(u8);
                n += (try reg.frontWriteStr("/sys/class/power_supply/")).len;
                n += (try reg.frontWriteStr(arg)).len;
                n += (try reg.frontWriteStr("/uevent\x00")).len;

                retptr.* = .{ .ps_name = arg, .path = reg.slice(u8, base, n)[0 .. n - 1 :0] };
                return retptr;
            }
        };

        pub const ReadData = struct {
            path: [:0]const u8,
            basename: []const u8,
            format: Format = .{},
            fg: color.Hex = .{},
            bg: color.Hex = .{},

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= WIDGET_BUF_MAX)
                    utl.fatal(&.{"READ: path too long"});

                const retptr = try reg.frontAlloc(@This());

                retptr.* = .{
                    .path = try reg.frontWriteStrZ(arg),
                    .basename = fs.path.basename(arg),
                };
                return retptr;
            }
        };

        pub const ArgRequired = MakeEnumSubset(
            Tag,
            &.{ .TIME, .DISK, .NET, .BAT, .READ },
        );

        pub const FormatRequired = MakeEnumSubset(
            Tag,
            &.{ .MEM, .CPU, .DISK, .NET, .BAT, .READ },
        );

        pub const ColorSupported = MakeEnumSubset(
            Tag,
            &.{ .MEM, .CPU, .DISK, .NET, .BAT },
        );

        pub const ColorOnlyDefault = MakeEnumSubset(
            Tag,
            &.{ .TIME, .READ },
        );

        pub fn castTo(self: @This(), comptime T: type) T {
            return @enumFromInt(@intFromEnum(self));
        }

        pub fn requiresArgParam(self: @This()) bool {
            _ = meta.intToEnum(ArgRequired, @intFromEnum(self)) catch return false;
            return true;
        }

        pub fn requiresFormatParam(self: @This()) bool {
            _ = meta.intToEnum(FormatRequired, @intFromEnum(self)) catch return false;
            return true;
        }

        pub fn supportsColor(self: @This()) bool {
            _ = meta.intToEnum(ColorSupported, @intFromEnum(self)) catch return false;
            return true;
        }
    };
};

pub const TimeOpt = enum {
    @"-",

    pub const ColorSupported = enum {};
};

pub const MemOpt = enum {
    @"%free",
    @"%available",
    @"%buffers",
    @"%cached",
    @"%used",
    total,
    free,
    available,
    buffers,
    cached,
    used,
    dirty,
    writeback,

    pub const ColorSupported = MakeEnumSubset(@This(), &.{
        .@"%free", .@"%available", .@"%buffers", .@"%cached", .@"%used",
    });
};
pub const CpuOpt = enum {
    @"%all",
    @"%user",
    @"%sys",
    all,
    user,
    sys,
    intr,
    ctxt,
    forks,
    running,
    blocked,
    softirq,
    brlbars,
    blkbars,

    pub const ColorSupported = MakeEnumSubset(@This(), &.{
        .@"%all", .@"%user", .@"%sys", .forks, .running, .blocked,
    });
};

pub const DiskOpt = enum {
    arg,
    @"%used",
    @"%free",
    @"%available",
    total,
    used,
    free,
    available,

    pub const ColorSupported = MakeEnumSubset(@This(), &.{
        .@"%used", .@"%free", .@"%available",
    });
};

pub const NetOpt = enum {
    arg,
    inet,
    flags,
    state,
    rx_bytes,
    rx_pkts,
    rx_errs,
    rx_drop,
    rx_multicast,
    tx_bytes,
    tx_pkts,
    tx_errs,
    tx_drop,

    // note that arg is a special case and it is a detail of the implementation
    // of the widget that it happens to be in the SocketRequired enum subset.
    // Thus a better name would be "StringProducing" or something like that.
    pub const SocketRequired = MakeEnumSubset(@This(), &.{ .arg, .inet, .flags, .state });
    pub const ProcNetDevRequired = MakeEnumSubset(@This(), &.{
        .rx_bytes,
        .rx_pkts,
        .rx_errs,
        .rx_drop,
        .rx_multicast,
        .tx_bytes,
        .tx_pkts,
        .tx_errs,
        .tx_drop,
    });

    pub const ColorSupported = MakeEnumSubset(@This(), &.{.state});

    pub fn castTo(self: @This(), comptime T: type) T {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn requiresSocket(self: @This()) bool {
        _ = meta.intToEnum(SocketRequired, @intFromEnum(self)) catch return false;
        return true;
    }

    pub fn requiresProcNetDev(self: @This()) bool {
        _ = meta.intToEnum(ProcNetDevRequired, @intFromEnum(self)) catch return false;
        return true;
    }
};

pub const BatOpt = enum {
    arg,
    @"%fullnow",
    @"%fulldesign",
    state,

    pub const ColorSupported = MakeEnumSubset(@This(), &.{
        .@"%fullnow", .@"%fulldesign", .state,
    });
};
pub const ReadOpt = enum {
    arg,
    basename,
    content,
    raw,

    pub const ColorSupported = enum {};
};

pub fn strStartToTaggedWidgetId(str: []const u8) ?Widget.Id {
    inline for (@typeInfo(Widget.Id.Tag).@"enum".fields) |field| {
        if (mem.startsWith(u8, str, field.name))
            return @unionInit(Widget.Id, field.name, undefined);
    }
    return null;
}

const WID_OPT_TYPE = &.{
    TimeOpt, MemOpt, CpuOpt, DiskOpt, NetOpt, BatOpt, ReadOpt,
};

comptime {
    if (Widget.Id.NR_WIDGETS != WID_OPT_TYPE.len)
        @compileError("Adjust WID_OPT_TYPE");
}

// == public constants ========================================================

/// Individual widget maximum buffer size.
pub const WIDGET_BUF_MAX = 256;

/// Names of options supported by widgets' formats keyed by
/// @intFromEnum(Widget.Id.Tag).
pub const WID_OPT_NAMES: [Widget.Id.NR_WIDGETS][]const [:0]const u8 = blk: {
    var w: [Widget.Id.NR_WIDGETS][]const [:0]const u8 = undefined;
    for (WID_OPT_TYPE, 0..) |T, i| {
        w[i] = meta.fieldNames(T);
    }
    break :blk w;
};

/// Particular widgets' format option state of color support keyed by
/// @intFromEnum(Widget.Id.Tag).
pub const WID_OPT_COLOR_SUPPORTED: [Widget.Id.NR_WIDGETS][]const bool = blk: {
    var w: [Widget.Id.NR_WIDGETS][]const bool = undefined;
    for (WID_OPT_TYPE, 0..) |T, i| {
        const len = @typeInfo(T).@"enum".fields.len;
        var supporting_color: [len]bool = .{false} ** len;
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
pub const WIDGET_INTERVAL_MAX = 1 << 31;

/// Maximum strftime(3) format size.
pub const STRFTIME_FORMAT_BUF_SIZE_MAX = WIDGET_BUF_MAX / 4;

/// Maximum strftime(3) output size.
pub const STRFTIME_OUT_BUF_SIZE_MAX = STRFTIME_FORMAT_BUF_SIZE_MAX * 2;

// == private =================================================================

fn MakeEnumSubset(comptime E: type, comptime new_values: []const E) type {
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
            .tag_type = math.IntFittingRange(0, new_val_max),
            .fields = &result,
            .decls = &.{},
            .is_exhaustive = E_enum.is_exhaustive,
        },
    });
}
