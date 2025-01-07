const cfg = @import("config.zig");
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
const enums = std.enums;
const mem = std.mem;
const meta = std.meta;

// == public types ============================================================

// 1/10th of a second
pub const DeciSec = u64;

pub const PartOpt = struct {
    pub const Flag = packed struct {
        diff: bool = false,
        quiet: bool = false,
    };
    part: []const u8,
    opt: u8 = 0,
    flags: Flag = .{},
    wopts: unt.NumUnit.WriteOptions = .{},
};

pub const Format = struct {
    part_opts: []PartOpt = &.{},
    part_last: []const u8 = &.{},
};

pub const Hex = struct {
    _hex: [7]u8 = .{0} ** 7,

    pub fn set(self: *@This(), str: []const u8) bool {
        if (str.len == 0 or mem.eql(u8, str, "default")) {
            @memset(&self._hex, 0);
            return true;
        }

        const hashash = @intFromBool(str[0] == '#');
        const ismini = (str.len - hashash) == 3;
        const isnormal = (str.len - hashash) == 6;

        if (!isnormal and !ismini) return false;

        for (str[hashash..]) |ch| switch (ch) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        };

        self._hex[0] = '#';
        if (ismini) {
            var i: usize = 1;
            for (str[hashash..]) |ch| {
                self._hex[i] = ch;
                i += 1;
                self._hex[i] = ch;
                i += 1;
            }
        } else {
            @memcpy(self._hex[1..], str[hashash..]);
        }
        return true;
    }

    pub fn get(self: *const @This()) ?*const [7]u8 {
        return if (self._hex[0] == 0) null else &self._hex;
    }
};

pub const ThreshHex = struct {
    thresh: u8,
    hex: Hex,
};

pub const OptColors = struct {
    opt: u8,
    colors: []ThreshHex,
};

pub const Color = union(enum) {
    nocolor,
    default: Hex,
    color: OptColors,

    pub fn getColor(
        self: *const @This(),
        with_checkOptColors: anytype,
    ) ?*const [7]u8 {
        return switch (self.*) {
            .nocolor => null,
            .default => |*hex| hex.get(),
            .color => |oc| with_checkOptColors.checkOptColors(oc),
        };
    }

    pub fn getDefault(self: *const @This()) ?*const [7]u8 {
        return switch (self.*) {
            .nocolor => null,
            .default => |*hex| hex.get(),
            .color => null,
        };
    }
};

pub const WidgetId = union(Tag) {
    TIME: *w_time.WidgetData,
    MEM: *w_mem.WidgetData,
    CPU: *w_cpu.WidgetData,
    DISK: *w_dysk.WidgetData,
    NET: *w_net.WidgetData,
    BAT: *w_bat.WidgetData,
    READ: *w_read.WidgetData,

    const NR_WIDGETS = @typeInfo(Tag).Enum.fields.len;

    const Tag = enum { TIME, MEM, CPU, DISK, NET, BAT, READ };

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
        return @as(T, @enumFromInt(@intFromEnum(self)));
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

pub const Widget = struct {
    wid: WidgetId,
    interval: DeciSec = WIDGET_INTERVAL_DEFAULT,
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
        return @as(T, @enumFromInt(@intFromEnum(self)));
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

pub fn strStartToTaggedWidgetId(str: []const u8) ?WidgetId {
    inline for (@typeInfo(WidgetId.Tag).Enum.fields) |field| {
        if (mem.startsWith(u8, str, field.name))
            return @unionInit(WidgetId, field.name, undefined);
    }
    return null;
}

const WID_OPT_TYPE = &.{
    TimeOpt, MemOpt, CpuOpt, DiskOpt, NetOpt, BatOpt, ReadOpt,
};

comptime {
    if (WidgetId.NR_WIDGETS != WID_OPT_TYPE.len)
        @compileError("Adjust WID_OPT_TYPE");
}

// == public constants ========================================================

/// Individual widget maximum buffer size.
pub const WIDGET_BUF_MAX = 256;

/// Names of options supported by widgets' formats keyed by
/// @intFromEnum(WidgetId.Tag).
pub const WID_OPT_NAMES: [WidgetId.NR_WIDGETS][]const [:0]const u8 = blk: {
    var w: [WidgetId.NR_WIDGETS][]const [:0]const u8 = undefined;
    for (WID_OPT_TYPE, 0..) |T, i| {
        w[i] = meta.fieldNames(T);
    }
    break :blk w;
};

/// Particular widgets' format option state of color support keyed by
/// @intFromEnum(WidgetId.Tag).
pub const WID_OPT_COLOR_SUPPORTED: [WidgetId.NR_WIDGETS][]const bool = blk: {
    var w: [WidgetId.NR_WIDGETS][]const bool = undefined;
    for (WID_OPT_TYPE, 0..) |T, i| {
        const len = @typeInfo(T).Enum.fields.len;
        var supporting_color: [len]bool = .{false} ** len;
        for (std.enums.values(T.ColorSupported)) |v| {
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

// == private =================================================================

fn MakeEnumSubset(comptime E: type, comptime new_values: []const E) type {
    const E_enum = @typeInfo(E).Enum;

    if (new_values.len == 0)
        @compileError("Attempted to create an `enum {}`");

    if (new_values.len > E_enum.fields.len)
        @compileError("Provided at least one duplicate enum field");

    var new_val_max = 0;
    var result: [new_values.len]std.builtin.Type.EnumField = undefined;
    for (new_values, 0..) |new_value, i| {
        const v = @intFromEnum(new_value);
        result[i] = .{ .name = @tagName(new_value), .value = v };
        new_val_max = @max(new_val_max, v);
    }
    return @Type(.{
        .Enum = .{
            .tag_type = std.math.IntFittingRange(0, new_val_max),
            .fields = &result,
            .decls = &.{},
            .is_exhaustive = E_enum.is_exhaustive,
        },
    });
}
