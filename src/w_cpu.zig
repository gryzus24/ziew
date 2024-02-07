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
    slots: [3]utl.F5014 = .{utl.F5014.init(0)} ** 3,

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
        var result: ?*const [7]u8 = null;
        const value = self.slots[mc.opt].dec();
        for (mc.colors) |*mcc| {
            if (value >= mcc.thresh) {
                result = mcc.getHex();
            } else {
                break;
            }
        }
        return result;
    }
};

pub fn update(stat: *const fs.File, old: *CpuState) void {
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

    const us_pdelta = utl.F5014.init((user_delta + sys_delta) * 100);
    const u_pdelta = utl.F5014.init(user_delta * 100);
    const s_pdelta = utl.F5014.init(sys_delta * 100);
    const total_delta = user_delta + sys_delta + idle_delta;

    old.slots[@intFromEnum(typ.CpuOpt.@"%all")] = us_pdelta.div(total_delta);
    old.slots[@intFromEnum(typ.CpuOpt.@"%user")] = u_pdelta.div(total_delta);
    old.slots[@intFromEnum(typ.CpuOpt.@"%sys")] = s_pdelta.div(total_delta);

    @memcpy(&old.fields, &new.fields);
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
        const value = state.slots[opt.opt].round(opt.precision);

        if (opt.alignment == .right)
            utl.writeF5014Alignment(writer, .percent, value);

        value.write(writer, opt.precision);
        utl.writeStr(writer, &[1]u8{'%'});

        if (opt.alignment == .left)
            utl.writeF5014Alignment(writer, .percent, value);

        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
