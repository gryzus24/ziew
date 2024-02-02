const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;

pub const MemState = struct {
    fields: [7]u64 = .{0} ** 7,

    pub fn total(self: @This()) u64 {
        return self.fields[0];
    }
    pub fn free(self: @This()) u64 {
        return self.fields[1];
    }
    pub fn avail(self: @This()) u64 {
        return self.fields[2];
    }
    pub fn buffers(self: @This()) u64 {
        return self.fields[3];
    }
    pub fn cached(self: @This()) u64 {
        return self.fields[4];
    }
    pub fn dirty(self: @This()) u64 {
        return self.fields[5];
    }
    pub fn writeback(self: @This()) u64 {
        return self.fields[6];
    }
    pub fn used(self: @This()) u64 {
        return self.total() - self.avail();
    }

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorAboveThreshold(
            switch (@as(typ.MemOpt, @enumFromInt(mc.opt))) {
                .@"%used" => utl.percentOf(self.used(), self.total()),
                .@"%free" => utl.percentOf(self.free(), self.total()),
                .@"%available" => utl.percentOf(self.avail(), self.total()),
                .@"%cached" => utl.percentOf(self.cached(), self.total()),
                .used => unreachable,
                .total => unreachable,
                .free => unreachable,
                .available => unreachable,
                .buffers => unreachable,
                .cached => unreachable,
                .dirty => unreachable,
                .writeback => unreachable,
            }.val,
            mc.colors,
        );
    }
};

pub fn update(meminfo: *const fs.File, old: *MemState) void {
    const MEMINFO_BUF_SIZE = 2048;
    const MEMINFO_KEY_LEN = "xxxxxxxx:       ".len;

    var meminfo_buf: [MEMINFO_BUF_SIZE]u8 = undefined;
    const nread = meminfo.pread(&meminfo_buf, 0) catch |err| {
        utl.fatal(&.{ "MEM: pread: ", @errorName(err) });
    };

    var i: usize = MEMINFO_KEY_LEN;
    var nvals: usize = 0;
    var ndigits: usize = 0;
    var skip: bool = false;
    while (i < nread) : (i += 1) switch (meminfo_buf[i]) {
        ' ' => {
            if (ndigits == 0) continue;
            if (!skip) {
                old.fields[nvals] = utl.unsafeAtou64(
                    meminfo_buf[i - ndigits .. i],
                );
                nvals += 1;
                if (nvals == old.fields.len) break;
                if (nvals == 5) skip = true; // skip lines after 'Cached'
            }
            ndigits = 0;
            i += "kB\n".len;
            if (meminfo_buf[i + 1] == 'D') skip = false; // Dirty
            i += MEMINFO_KEY_LEN;
        },
        '0'...'9' => ndigits += 1,
        else => {},
    };
}

pub fn widget(
    stream: anytype,
    state: *const MemState,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    const writer = stream.writer();

    utl.writeBlockStart(writer, fg.getColor(state), bg.getColor(state));
    utl.writeStr(writer, wf.parts[0]);
    for (wf.iterOpts(), wf.iterParts()[1..]) |*opt, *part| {
        const nu = switch (@as(typ.MemOpt, @enumFromInt(opt.opt))) {
            .@"%used" => utl.percentOf(state.used(), state.total()),
            .@"%free" => utl.percentOf(state.free(), state.total()),
            .@"%available" => utl.percentOf(state.avail(), state.total()),
            .@"%cached" => utl.percentOf(state.cached(), state.total()),
            .used => utl.kbToHuman(state.used()),
            .total => utl.kbToHuman(state.total()),
            .free => utl.kbToHuman(state.free()),
            .available => utl.kbToHuman(state.avail()),
            .buffers => utl.kbToHuman(state.buffers()),
            .cached => utl.kbToHuman(state.cached()),
            .dirty => utl.kbToHuman(state.dirty()),
            .writeback => utl.kbToHuman(state.writeback()),
        };
        utl.writeNumUnit(writer, nu, opt.alignment, opt.precision);
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
