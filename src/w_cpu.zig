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
    var statbuf: [256]u8 = undefined;

    const nread = proc_stat.pread(&statbuf, 0) catch |err| {
        utl.fatal(&.{ "CPU: pread: ", @errorName(err) });
    };

    var cur: ProcStat = .{ .fields = undefined };
    var nvals: usize = 0;
    var ndigits: usize = 0;
    out: for ("cpu".len..nread) |i| switch (statbuf[i]) {
        ' ', '\n' => {
            if (ndigits > 0) {
                cur.fields[nvals] = utl.unsafeAtou64(statbuf[i - ndigits .. i]);
                nvals += 1;
                if (nvals == cur.fields.len) break :out;
                ndigits = 0;
            }
        },
        '0'...'9' => ndigits += 1,
        else => {},
    };

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
    const ch = ColorHandler{ .slots = &slots };

    utl.writeBlockStart(writer, fg.getColor(ch), bg.getColor(ch));
    utl.writeStr(writer, cf.parts[0]);
    for (cf.iterOpts(), cf.iterParts()[1..]) |*opt, *part| {
        const value = slots[opt.opt];

        if (opt.alignment == .right)
            utl.writeAlignment(writer, .percent, value, opt.precision);

        utl.writeFloat(writer, value, opt.precision);
        utl.writeStr(writer, "%");

        if (opt.alignment == .left)
            utl.writeAlignment(writer, .percent, value, opt.precision);

        utl.writeStr(writer, part.*);
    }

    @memcpy(&prev.fields, &cur.fields);

    return utl.writeBlockEnd_GetWritten(stream);
}
