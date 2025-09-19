const cfg = @import("config.zig");
const color = @import("color.zig");
const log = @import("log.zig");
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
const io = std.io;
const linux = std.os.linux;
const math = std.math;
const mem = std.mem;
const meta = std.meta;

// == public types ============================================================

// 1/10th of a second
pub const DeciSec = u32;

pub const Format = struct {
    parts: m.MemSlice(Part),
    last_str: m.MemSlice(u8),

    pub const zero: Format = .{ .parts = .zero, .last_str = .zero };

    pub const Part = struct {
        str: m.MemSlice(u8),
        opt: u8,
        diff: bool,
        quiet: bool,
        wopts: unt.NumUnit.WriteOptions,

        pub fn initDefault(opt: u8) @This() {
            return .{
                .str = .zero,
                .opt = opt,
                .diff = false,
                .quiet = false,
                .wopts = .default,
            };
        }
    };
};

pub const Widget = struct {
    wid: Id,
    interval: DeciSec,
    interval_now: DeciSec,
    fg: Color,
    bg: Color,

    pub fn initDefault(wid: Id) @This() {
        return .{
            .wid = wid,
            .interval = WIDGET_INTERVAL_DEFAULT,
            .interval_now = 0,
            .fg = .{ .static = .default },
            .bg = .{ .static = .default },
        };
    }

    pub const Color = union(enum) {
        active: color.Active,
        static: color.Hex,
    };

    pub inline fn check(
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

    pub const NoopIndirect = struct {
        pub fn checkPairs(other: @This(), active: color.Active, base: [*]const u8) color.Hex {
            _ = other;
            _ = active;
            _ = base;
            return .default;
        }
    };

    pub const Id = union(Tag) {
        TIME: *TimeData,
        MEM: *MemData,
        CPU: *CpuData,
        DISK: *DiskData,
        NET: *NetData,
        BAT: *BatData,
        READ: *ReadData,

        const DATA_SIZE_MAX = 64;

        comptime {
            if (@sizeOf(TimeData) > DATA_SIZE_MAX) unreachable;
            if (@sizeOf(MemData) > DATA_SIZE_MAX) unreachable;
            if (@sizeOf(CpuData) > DATA_SIZE_MAX) unreachable;
            if (@sizeOf(DiskData) > DATA_SIZE_MAX) unreachable;
            if (@sizeOf(NetData) > DATA_SIZE_MAX) unreachable;
            if (@sizeOf(BatData) > DATA_SIZE_MAX) unreachable;
            if (@sizeOf(ReadData) > DATA_SIZE_MAX) unreachable;
        }

        const Tag = enum { TIME, MEM, CPU, DISK, NET, BAT, READ };

        const NR_WIDGETS = @typeInfo(Tag).@"enum".fields.len;

        pub const TimeData = struct {
            format: [FORMAT_SIZE]u8,

            const FORMAT_SIZE = DATA_SIZE_MAX / 2;

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= FORMAT_SIZE)
                    log.fatal(&.{"TIME: strftime format too long"});

                const ret = try reg.frontAlloc(@This());
                @memcpy(ret.format[0..arg.len], arg);
                ret.format[arg.len] = 0;
                return ret;
            }

            pub fn getFormat(self: *const @This()) [*:0]const u8 {
                return @ptrCast(&self.format);
            }
        };

        pub const MemData = struct {
            format: Format,

            pub fn init(reg: *m.Region) !*@This() {
                const ret = try reg.frontAlloc(@This());
                ret.* = .{ .format = .zero };
                return ret;
            }
        };

        pub const CpuData = struct {
            format: Format,

            pub fn init(reg: *m.Region) !*@This() {
                const ret = try reg.frontAlloc(@This());
                ret.* = .{ .format = .zero };
                return ret;
            }
        };

        pub const DiskData = struct {
            format: Format,
            len: u8,
            mountpoint: [MOUNTPOINT_SIZE]u8,

            const MOUNTPOINT_SIZE = DATA_SIZE_MAX - 1 - @sizeOf(Format);

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= MOUNTPOINT_SIZE)
                    log.fatal(&.{"DISK: mountpoint path too long"});

                const ret = try reg.frontAlloc(@This());
                ret.format = .zero;
                ret.len = @intCast(arg.len);
                @memcpy(ret.mountpoint[0..arg.len], arg);
                ret.mountpoint[arg.len] = 0;
                return ret;
            }

            pub fn getMountpoint(self: *const @This()) [:0]const u8 {
                return self.mountpoint[0..self.len :0];
            }
        };

        pub const NetData = struct {
            format: Format,
            ifr: linux.ifreq,

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                var ifr: linux.ifreq = undefined;
                if (arg.len >= ifr.ifrn.name.len)
                    log.fatal(&.{ "NET: interface name too long: ", arg });

                const ret = try reg.frontAlloc(@This());
                @memset(ifr.ifrn.name[0..], 0);
                @memcpy(ifr.ifrn.name[0..arg.len], arg);
                ret.* = .{ .ifr = ifr, .format = .zero };
                return ret;
            }
        };

        pub const BatData = struct {
            format: Format,
            ps_off: u8,
            ps_len: u8,
            path: [PATH_SIZE]u8,

            const PATH_SIZE = DATA_SIZE_MAX - @sizeOf(Format) - 1 - 1;

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= 16) log.fatal(&.{"BAT: battery name too long"});

                const ret = try reg.frontAlloc(@This());
                ret.format = .zero;
                var fw: io.Writer = .fixed(&ret.path);
                utl.writeStr(&fw, "/sys/class/power_supply/");
                ret.ps_off = @intCast(fw.end);
                ret.ps_len = @intCast(arg.len);
                utl.writeStr(&fw, arg);
                utl.writeStr(&fw, "/uevent\x00");
                return ret;
            }

            pub fn getPath(self: *const @This()) [*:0]const u8 {
                return @ptrCast(&self.path);
            }

            pub fn getPsName(self: *const @This()) []const u8 {
                return self.path[self.ps_off..][0..self.ps_len];
            }
        };

        pub const ReadData = struct {
            format: Format,
            basename_off: u8,
            basename_len: u8,
            path: [PATH_SIZE]u8,

            const PATH_SIZE = DATA_SIZE_MAX - @sizeOf(Format) - 1 - 1;

            pub fn init(reg: *m.Region, arg: []const u8) !*@This() {
                if (arg.len >= PATH_SIZE)
                    log.fatal(&.{"READ: path too long"});

                const ret = try reg.frontAlloc(@This());
                ret.format = .zero;
                var fw: io.Writer = .fixed(&ret.path);
                utl.writeStr(&fw, arg);
                utl.writeStr(&fw, "\x00");
                const basename = fs.path.basename(fw.buffered());
                ret.basename_off = @intCast(
                    mem.indexOf(u8, &ret.path, basename) orelse unreachable,
                );
                ret.basename_len = @intCast(basename.len);
                return ret;
            }

            pub fn getPath(self: *const @This()) [*:0]const u8 {
                return @ptrCast(&self.path);
            }

            pub fn getBasename(self: *const @This()) []const u8 {
                return self.path[self.basename_off..][0..self.basename_len];
            }
        };

        pub const AcceptsArg = MakeEnumSubset(
            Tag,
            &.{ .TIME, .DISK, .NET, .BAT, .READ },
        );

        pub const AcceptsFormat = MakeEnumSubset(
            Tag,
            &.{ .MEM, .CPU, .DISK, .NET, .BAT, .READ },
        );

        pub const ActiveColorSupported = MakeEnumSubset(
            Tag,
            &.{ .MEM, .CPU, .DISK, .NET, .BAT },
        );

        pub const DefaultColorOnly = MakeEnumSubset(
            Tag,
            &.{ .TIME, .READ },
        );

        pub fn castTo(self: @This(), comptime T: type) T {
            return @enumFromInt(@intFromEnum(self));
        }

        pub fn acceptsArg(self: @This()) bool {
            _ = meta.intToEnum(AcceptsArg, @intFromEnum(self)) catch return false;
            return true;
        }

        pub fn acceptsFormat(self: @This()) bool {
            _ = meta.intToEnum(AcceptsFormat, @intFromEnum(self)) catch return false;
            return true;
        }

        pub fn supportsActiveColor(self: @This()) bool {
            _ = meta.intToEnum(ActiveColorSupported, @intFromEnum(self)) catch return false;
            return true;
        }

        pub fn supportsDefaultColorOnly(self: @This()) bool {
            _ = meta.intToEnum(DefaultColorOnly, @intFromEnum(self)) catch return false;
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

/// Names of options supported by widgets' formats keyed by
/// @intFromEnum(Widget.Id.Tag).
pub const WID__OPT_NAMES: [Widget.Id.NR_WIDGETS][]const [:0]const u8 = blk: {
    var w: [Widget.Id.NR_WIDGETS][]const [:0]const u8 = undefined;
    for (WID_OPT_TYPE, 0..) |T, i| {
        w[i] = meta.fieldNames(T);
    }
    break :blk w;
};

/// Particular widgets' format option state of color support keyed by
/// @intFromEnum(Widget.Id.Tag).
pub const WID__OPTS_SUPPORTING_COLOR: [Widget.Id.NR_WIDGETS][]const bool = blk: {
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

/// Individual widget maximum buffer size.
pub const WIDGET_BUF_MAX = 128;

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
