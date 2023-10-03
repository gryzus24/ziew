const std = @import("std");
const mem = std.mem;

pub const WidgetId = enum {
    TIME,
    MEM,
    CPU,
    LOAD,
    DISK,
};

pub const TimeOpt = enum {
    @"-",
};

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

pub const CpuOpt = enum {
    @"%all",
    @"%user",
    @"%sys",
};

pub const LoadOpt = enum {
    @"1",
    @"5",
    @"15",
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

// 1/10 of a second
pub const DeciSec = u32;

pub const WIDGETS_MAX = @typeInfo(WidgetId).Enum.fields.len;
pub const WIDGET_BUF_BYTES_MAX = 128;
pub const WIDGET_TYPES = .{ TimeOpt, MemOpt, CpuOpt, LoadOpt, DiskOpt };

pub const OPTS_MAX = blk: {
    var max: usize = 0;
    for (WIDGET_TYPES) |t| {
        const n = @typeInfo(t).Enum.fields.len;
        if (n > max)
            max = n;
    }
    break :blk max;
};

pub const PARTS_MAX = OPTS_MAX + 1;

pub const OPT_NAME_BUF_MAX = blk: {
    var max: usize = 0;
    for (WIDGET_TYPES) |t| {
        const enum_t = @typeInfo(t).Enum;
        for (enum_t.fields) |field| if (field.name.len > max) {
            max = field.name.len;
        };
    }
    // [.] [precision] [alignment]
    break :blk max + 3;
};

pub const WID_TO_OPT_NAMES: [WIDGETS_MAX][]const []const u8 = blk: {
    var w: [WIDGETS_MAX][]const []const u8 = undefined;
    for (WIDGET_TYPES, 0..) |t, i| {
        const enum_t = @typeInfo(t).Enum;
        var q: [enum_t.fields.len][]const u8 = undefined;
        for (enum_t.fields, 0..) |field, j| {
            q[j] = field.name;
        }
        w[i] = &q;
    }
    break :blk w;
};

pub fn widStrToEnum(str: []const u8) ?WidgetId {
    if (mem.eql(u8, str, "TIME")) {
        return WidgetId.TIME;
    } else if (mem.eql(u8, str, "MEM")) {
        return WidgetId.MEM;
    } else if (mem.eql(u8, str, "CPU")) {
        return WidgetId.CPU;
    } else if (mem.eql(u8, str, "LOAD")) {
        return WidgetId.LOAD;
    } else if (mem.eql(u8, str, "DISK")) {
        return WidgetId.DISK;
    } else {
        return null;
    }
}

pub fn widSupportsDefaultColor(wid: u8) bool {
    return switch (@as(WidgetId, @enumFromInt(wid))) {
        .TIME,
        .MEM,
        .CPU,
        .LOAD,
        .DISK,
        => true,
        else => false,
    };
}

pub fn widSupportsManyColors(wid: u8) bool {
    return switch (@as(WidgetId, @enumFromInt(wid))) {
        .MEM,
        .CPU,
        .DISK,
        => true,
        .TIME,
        .LOAD,
        => false,
    };
}
