const std = @import("std");
const utl = @import("util.zig");
const mem = std.mem;

pub const WidgetId = enum { TIME, MEM, CPU, LOAD, DISK, ETH };
pub const WIDGETS_MAX = @typeInfo(WidgetId).Enum.fields.len;
pub const WIDGET_BUF_BYTES_MAX = 128;

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
};
pub const CpuOpt = enum { @"%all", @"%user", @"%sys" };
pub const LoadOpt = enum { @"1", @"5", @"15" };
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
pub const EthOpt = enum { ifname, inet, flags, state, @"-" };
pub const OPT_TYPES = .{ TimeOpt, MemOpt, CpuOpt, LoadOpt, DiskOpt, EthOpt };
pub const OPTS_MAX = blk: {
    var max: usize = 0;
    for (OPT_TYPES) |t| {
        const n = @typeInfo(t).Enum.fields.len;
        if (n > max)
            max = n;
    }
    break :blk max;
};
pub const PARTS_MAX = OPTS_MAX + 1;
pub const OPT_NAME_BUF_MAX = blk: {
    var max: usize = 0;
    for (OPT_TYPES) |t| {
        const enum_t = @typeInfo(t).Enum;
        for (enum_t.fields) |field| if (field.name.len > max) {
            max = field.name.len;
        };
    }
    // + space for [.] [precision] [alignment]
    break :blk max + 3;
};

pub const WID_TO_OPT_NAMES: [WIDGETS_MAX][]const []const u8 = blk: {
    var w: [WIDGETS_MAX][]const []const u8 = undefined;
    for (OPT_TYPES, 0..) |t, i| {
        const enum_t = @typeInfo(t).Enum;
        var q: [enum_t.fields.len][]const u8 = undefined;
        for (enum_t.fields, 0..) |field, j| {
            q[j] = field.name;
        }
        w[i] = &q;
    }
    break :blk w;
};

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

pub fn knobSupportsManyColors(wid: WidgetId) bool {
    return switch (wid) {
        .MEM, .CPU, .DISK, .ETH => true,
        .TIME, .LOAD => false,
    };
}

pub fn knobValidManyColorsOptname(wid: WidgetId, optname: []const u8) bool {
    return switch (wid) {
        .TIME, .LOAD => false,
        .MEM, .CPU, .DISK => optname[0] == '%',
        .ETH => mem.eql(u8, optname, "state"),
    };
}

pub fn knobVerifyArgs(wid: WidgetId, opts: [*]const u8, nparts: u8) void {
    switch (wid) {
        .DISK, .ETH => {
            const sep_enum_value = switch (wid) {
                .DISK => @intFromEnum(DiskOpt.@"-"),
                .ETH => @intFromEnum(EthOpt.@"-"),
                else => unreachable,
            };
            const nargs = blk: {
                var n: u8 = 0;
                for (0..nparts - 1) |i| if (opts[i] == sep_enum_value) {
                    n += 1;
                };
                break :blk n;
            };
            if (nargs == 0 or opts[0] != sep_enum_value) {
                const argname = switch (wid) {
                    .DISK => "<mountpoint>",
                    .ETH => "<interface>",
                    else => unreachable,
                };
                utl.fatal("config: {s}: requires argument {s}", .{ @tagName(wid), argname });
            }
            if (nargs > 1)
                utl.fatal("config: {s}: too many arguments", .{@tagName(wid)});
        },
        .TIME, .MEM, .CPU, .LOAD => {},
    }
}

// 1/10 of a second
pub const DeciSec = u32;
