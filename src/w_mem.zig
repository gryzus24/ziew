const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;

const ColorHandler = struct {
    meminfo: *const MemInfo,

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        const mi = self.meminfo;
        return color.firstColorAboveThreshold(
            switch (@as(typ.MemOpt, @enumFromInt(mc.opt))) {
                .@"%used" => utl.percentOf(mi.used(), mi.total()),
                .@"%free" => utl.percentOf(mi.free(), mi.total()),
                .@"%available" => utl.percentOf(mi.avail(), mi.total()),
                .@"%cached" => utl.percentOf(mi.cached(), mi.total()),
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

const MemInfo = struct {
    fields: [7]u64,

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
};

pub fn widget(
    stream: anytype,
    proc_meminfo: *const fs.File,
    cf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    const MEMINFO_BUF_SIZE = 2048;
    const MEMINFO_KEY_LEN = "xxxxxxxx:       ".len;

    var meminfo_buf: [MEMINFO_BUF_SIZE]u8 = undefined;
    const nread = proc_meminfo.pread(&meminfo_buf, 0) catch |err| {
        utl.fatal(&.{ "MEM: pread: ", @errorName(err) });
    };

    var meminfo: MemInfo = .{ .fields = undefined };

    var i: usize = MEMINFO_KEY_LEN;
    var nvals: usize = 0;
    var ndigits: usize = 0;
    var skip: bool = false;
    while (i < nread) : (i += 1) switch (meminfo_buf[i]) {
        ' ' => {
            if (ndigits == 0) continue;
            if (!skip) {
                meminfo.fields[nvals] = utl.unsafeAtou64(
                    meminfo_buf[i - ndigits .. i],
                );
                nvals += 1;
                if (nvals == meminfo.fields.len) break;
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

    const writer = stream.writer();
    const ch: ColorHandler = .{ .meminfo = &meminfo };

    utl.writeBlockStart(writer, fg.getColor(ch), bg.getColor(ch));
    utl.writeStr(writer, cf.parts[0]);
    for (cf.iterOpts(), cf.iterParts()[1..]) |*opt, *part| {
        const nu = switch (@as(typ.MemOpt, @enumFromInt(opt.opt))) {
            .@"%used" => utl.percentOf(meminfo.used(), meminfo.total()),
            .@"%free" => utl.percentOf(meminfo.free(), meminfo.total()),
            .@"%available" => utl.percentOf(meminfo.avail(), meminfo.total()),
            .@"%cached" => utl.percentOf(meminfo.cached(), meminfo.total()),
            .used => utl.kbToHuman(meminfo.used()),
            .total => utl.kbToHuman(meminfo.total()),
            .free => utl.kbToHuman(meminfo.free()),
            .available => utl.kbToHuman(meminfo.avail()),
            .buffers => utl.kbToHuman(meminfo.buffers()),
            .cached => utl.kbToHuman(meminfo.cached()),
            .dirty => utl.kbToHuman(meminfo.dirty()),
            .writeback => utl.kbToHuman(meminfo.writeback()),
        };
        utl.writeNumUnit(writer, nu, opt.alignment, opt.precision);
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
