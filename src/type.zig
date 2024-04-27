const cfg = @import("config.zig");
const std = @import("std");
const utl = @import("util.zig");
const mem = std.mem;

pub const WidgetId = enum {
    TIME,
    MEM,
    CPU,
    DISK,
    NET,
    BAT,
    READ,

    fn argsepOptValue(self: @This()) ?u8 {
        return switch (self) {
            .DISK => @intFromEnum(DiskOpt.@"-"),
            .NET => @intFromEnum(NetOpt.@"-"),
            .BAT => @intFromEnum(BatOpt.@"-"),
            .READ => @intFromEnum(ReadOpt.@"-"),
            else => return null,
        };
    }

    pub fn panicOnInvalidArgs(self: @This(), wf: *const cfg.WidgetFormat) void {
        const argsep = self.argsepOptValue() orelse return;
        const nargs = blk: {
            var n: usize = 0;
            for (wf.iterOpts()) |*opt| if (opt.opt == argsep) {
                n += 1;
            };
            break :blk n;
        };
        if (nargs == 0 or wf.opts[0].opt != argsep) {
            const placeholder = switch (self) {
                .DISK => "<mountpoint>",
                .NET => "<interface>",
                .BAT => "<battery name>",
                .READ => "<filepath>",
                else => unreachable,
            };
            utl.fatal(&.{ "config: ", @tagName(self), ": requires argument ", placeholder });
        }
        if (nargs > 1)
            utl.fatal(&.{ "config: ", @tagName(self), ": too many arguments" });
    }

    pub fn supportsManyColors(self: @This()) bool {
        return switch (self) {
            .MEM, .CPU, .DISK, .NET, .BAT => true,
            .TIME, .READ => false,
        };
    }

    pub fn isManyColorsOptnameSupported(self: @This(), optname: []const u8) bool {
        return switch (self) {
            .TIME, .READ => false,
            .MEM, .CPU, .DISK => optname[0] == '%',
            .NET => mem.eql(u8, optname, "state"),
            .BAT => optname[0] == '%' or mem.eql(u8, optname, "state"),
        };
    }
};

pub const TimeOpt = enum { @"-" };
pub const MemOpt = enum {
    @"%used",
    // total
    @"%free",
    @"%available",
    // buffers
    @"%cached",
    used,
    total,
    free,
    available,
    buffers,
    cached,
    dirty,
    writeback,
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
    visubars,
};
pub const DiskOpt = enum {
    @"%used",
    // total
    @"%free",
    @"%available",
    used,
    total,
    free,
    available,
    @"-",
};
pub const NetOpt = enum { ifname, inet, flags, state, @"-" };
pub const BatOpt = enum { @"%fullnow", @"%fulldesign", state, @"-" };
pub const ReadOpt = enum { basename, content, raw, @"-" };

// 1/10th of a second
pub const DeciSec = u64;

// == CONSTANTS ===============================================================

const _WIDGET_IDS_NUM = @typeInfo(WidgetId).Enum.fields.len;

const _OPT_TYPES = blk: {
    const w = .{ TimeOpt, MemOpt, CpuOpt, DiskOpt, NetOpt, BatOpt, ReadOpt };
    if (w.len != _WIDGET_IDS_NUM)
        @compileError("adjust _OPT_TYPES");
    break :blk w;
};

// maximum number of widgets that can be configured
pub const WIDGETS_MAX = 16;

// individual widget maximum buffer size
pub const WIDGET_BUF_MAX = 256;

// maximum number of options that can be used in a widget format
pub const OPTS_MAX = blk: {
    var max: usize = 0;
    for (_OPT_TYPES) |t| {
        const n = @typeInfo(t).Enum.fields.len;
        if (n > max)
            max = n;
    }
    break :blk max;
};

// maximum number of parts that can be present in a widget format
pub const PARTS_MAX = OPTS_MAX + 1;

// size of a buffer that can hold the longest option name
pub const OPT_NAME_BUF_MAX = blk: {
    var max: usize = 0;
    for (_OPT_TYPES) |t| {
        const enum_t = @typeInfo(t).Enum;
        for (enum_t.fields) |field| if (field.name.len > max) {
            max = field.name.len;
        };
    }
    // + space for [.] [precision] [alignment]
    break :blk max + 3;
};

// option names of a widget @intFromEnum(WidgetId)
pub const WID_TO_OPT_NAMES: [_WIDGET_IDS_NUM][]const []const u8 = blk: {
    var w: [_WIDGET_IDS_NUM][]const []const u8 = undefined;
    for (_OPT_TYPES, 0..) |t, i| {
        const enum_t = @typeInfo(t).Enum;
        const names = inner: {
            var q: [enum_t.fields.len][]const u8 = undefined;
            for (enum_t.fields, 0..) |field, j| q[j] = field.name;
            break :inner q;
        };
        w[i] = &names;
    }
    break :blk w;
};

// maximum config file size
pub const CONFIG_FILE_BUF_MAX = 2048 + 1024;

pub const WIDGET_INTERVAL_DEFAULT = 50;
pub const WIDGET_INTERVAL_MAX = 1 << 31;

pub fn strToWidEnum(str: []const u8) ?WidgetId {
    inline for (@typeInfo(WidgetId).Enum.fields) |field| {
        if (mem.eql(u8, str, field.name))
            return @enumFromInt(field.value);
    }
    return null;
}

pub fn strStartToWidEnum(str: []const u8) ?WidgetId {
    inline for (@typeInfo(WidgetId).Enum.fields) |field| {
        if (mem.startsWith(u8, str, field.name))
            return @enumFromInt(field.value);
    }
    return null;
}
