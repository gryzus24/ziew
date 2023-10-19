const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const math = std.math;

pub const ProcStat = struct {
    fields: [10]u64,

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
};

const ColorHandler = struct {
    slots: *const [3]f64,

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(self.slots[mc.opt], mc.colors);
    }
};

pub fn widget(
    stream: anytype,
    proc_stat: *const fs.File,
    prev: *ProcStat,
    cf: *const cfg.ConfigFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    var stat_buf: [128]u8 = undefined;

    const nread = proc_stat.pread(&stat_buf, 0) catch |err|
        utl.fatal("CPU: pread: {}", .{err});

    var state_fields = mem.tokenizeScalar(
        u8,
        stat_buf[0..mem.indexOfScalar(u8, stat_buf[0..nread], '\n').?],
        ' ',
    );
    _ = state_fields.next().?;

    var i: usize = 0;
    var cur: ProcStat = .{ .fields = undefined };
    while (state_fields.next()) |field| {
        const value = fmt.parseUnsigned(u64, field, 10) catch unreachable;
        cur.fields[i] = value;
        i += 1;
    }

    const user_delta: f64 = @floatFromInt(cur.user() - prev.user());
    const sys_delta: f64 = @floatFromInt(cur.sys() - prev.sys());
    const idle_delta: f64 = @floatFromInt(cur.idle() - prev.idle());
    const total_delta = user_delta + sys_delta + idle_delta;

    const user = user_delta / total_delta * 100;
    const sys = sys_delta / total_delta * 100;

    const slots = blk: {
        var w: [3]f64 = undefined;
        w[@intFromEnum(typ.CpuOpt.@"%all")] = user + sys;
        w[@intFromEnum(typ.CpuOpt.@"%user")] = user;
        w[@intFromEnum(typ.CpuOpt.@"%sys")] = sys;
        break :blk w;
    };

    const writer = stream.writer();
    const color_handler = ColorHandler{ .slots = &slots };

    utl.writeBlockStart(
        writer,
        color.colorFromColorUnion(fg, color_handler),
        color.colorFromColorUnion(bg, color_handler),
    );
    utl.writeStr(writer, cf.parts[0]);
    for (0..cf.nparts - 1) |j| {
        const value = slots[cf.opts[j]];
        const prec = cf.opts_precision[j];
        const ali = cf.opts_alignment[j];

        if (ali == .right)
            utl.writeAlignment(writer, .percent, value, prec);

        utl.writeFloat(writer, value, prec);
        utl.writeStr(writer, "%");

        if (ali == .left)
            utl.writeAlignment(writer, .percent, value, prec);

        utl.writeStr(writer, cf.parts[1 + j]);
    }

    @memcpy(&prev.fields, &cur.fields);

    return utl.writeBlockEnd_GetWritten(stream);
}
