const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const math = std.math;
const mem = std.mem;

pub const CpuState = struct {
    fields: [10]u64 = .{0} ** 10,
    slots: [3]f64 = .{0} ** 3,

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

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(self.slots[mc.opt], mc.colors);
    }
};

pub fn update(stat: *const fs.File, old: *const CpuState) CpuState {
    var statbuf: [256]u8 = undefined;

    const nread = stat.pread(&statbuf, 0) catch |err| {
        utl.fatal(&.{ "CPU: pread: ", @errorName(err) });
    };

    var new: CpuState = .{};
    var nvals: usize = 0;
    var ndigits: usize = 0;
    for ("cpu".len..nread) |i| switch (statbuf[i]) {
        ' ', '\n' => {
            if (ndigits > 0) {
                new.fields[nvals] = utl.unsafeAtou64(statbuf[i - ndigits .. i]);
                nvals += 1;
                if (nvals == new.fields.len) break;
                ndigits = 0;
            }
        },
        '0'...'9' => ndigits += 1,
        else => {},
    };

    const user_delta = new.user() - old.user();
    const sys_delta = new.sys() - old.sys();
    const idle_delta = new.idle() - old.idle();

    const us_delta: f64 = @floatFromInt(user_delta + sys_delta);
    const u_delta: f64 = @floatFromInt(user_delta);
    const s_delta: f64 = @floatFromInt(sys_delta);
    const total_delta: f64 = @floatFromInt(user_delta + sys_delta + idle_delta);

    new.slots[@intFromEnum(typ.CpuOpt.@"%all")] = us_delta / total_delta * 100;
    new.slots[@intFromEnum(typ.CpuOpt.@"%user")] = u_delta / total_delta * 100;
    new.slots[@intFromEnum(typ.CpuOpt.@"%sys")] = s_delta / total_delta * 100;

    return new;
}

pub fn widget(
    stream: anytype,
    state: *const CpuState,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    const writer = stream.writer();

    utl.writeBlockStart(writer, fg.getColor(state), bg.getColor(state));
    utl.writeStr(writer, wf.parts[0]);
    for (wf.iterOpts(), wf.iterParts()[1..]) |*opt, *part| {
        const value = state.slots[opt.opt];

        if (opt.alignment == .right)
            utl.writeAlignment(writer, .percent, value, opt.precision);

        utl.writeFloat(writer, value, opt.precision);
        utl.writeStr(writer, &[1]u8{'%'});

        if (opt.alignment == .left)
            utl.writeAlignment(writer, .percent, value, opt.precision);

        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
