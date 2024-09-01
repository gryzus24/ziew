const std = @import("std");
const typ = @import("type.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const linux = std.os.linux;
const mem = std.mem;

// zig fmt: off
pub const c = @cImport({
    @cInclude("errno.h");      // errno constants
    @cInclude("net/if.h");     // IFF_* definitions
    @cInclude("sys/ioctl.h");  // SIOCGIFADDR, SIOCGIFFLAGS definitions
    @cInclude("sys/statfs.h"); // statfs()
    @cInclude("time.h");       // strftime() etc.
});
// zig fmt: on

fn writeAlignment(with_write: anytype, value: u64, digits_max: u8) void {
    const space_left = digits_max -| @as(u8, switch (value) {
        0...9 => 1,
        10...99 => 2,
        100...999 => 3,
        else => 4,
    });
    writeStr(with_write, (" " ** 0x10)[0 .. space_left & 0x0f]);
}

pub const F5608 = struct {
    u: u64,

    pub const FRAC_SHIFT = 8;
    pub const FRAC_MASK: u64 = (1 << FRAC_SHIFT) - 1;

    pub const ROUND_EPS = [_]u64{
        ((1 << FRAC_SHIFT) + 1) / 2,
        ((1 << FRAC_SHIFT) + 19) / 20,
        ((1 << FRAC_SHIFT) + 199) / 200,
    };
    comptime {
        for (ROUND_EPS) |e| {
            if (e <= 1)
                @compileError("FRAC_SHIFT too low to satisfy rounding precision");
        }
    }

    pub const PRECISION_MAX = ROUND_EPS.len;
    pub const FRAC_PRECISION_MULS: [PRECISION_MAX + 1]u64 = .{ 1, 10, 100, 1000 };

    pub fn whole(self: @This()) u64 {
        return self.u >> FRAC_SHIFT;
    }

    pub fn frac(self: @This()) u64 {
        return self.u & FRAC_MASK;
    }

    pub fn init(n: u64) F5608 {
        return .{ .u = n << FRAC_SHIFT };
    }

    pub fn add(self: @This(), n: u64) F5608 {
        return .{ .u = self.u + (n << FRAC_SHIFT) };
    }

    pub fn mul(self: @This(), n: u64) F5608 {
        return .{ .u = self.u * n };
    }

    pub fn div(self: @This(), n: u64) F5608 {
        return .{ .u = self.u / n };
    }

    fn _roundup(self: @This(), quants: u64) F5608 {
        return .{ .u = (self.u + quants - 1) / quants * quants };
    }

    fn _round(self: @This(), precision: u8) F5608 {
        return if (precision < ROUND_EPS.len)
            self._roundup(ROUND_EPS[precision])
        else
            self;
    }

    pub fn roundAndTruncate(self: @This()) u64 {
        return self._round(0).whole();
    }

    pub fn write(
        self: @This(),
        with_write: anytype,
        digits_max: u8,
        alignment: typ.Alignment,
        precision: u8,
        unitchar: u8,
    ) void {
        const rounded = self._round(precision);
        const int = rounded.whole();

        if (alignment == .right)
            writeAlignment(with_write, int, digits_max);

        writeInt(with_write, int);
        if (precision > 0) {
            const fpmul = FRAC_PRECISION_MULS[@min(precision, FRAC_PRECISION_MULS.len - 1)];

            writeStr(with_write, &[1]u8{'.'});
            writeIntOpts(
                with_write,
                (rounded.frac() * fpmul) / (1 << FRAC_SHIFT),
                .{ .width = precision, .alignment = .right, .fill = '0' },
            );
        }
        if (unitchar != '\x00')
            writeStr(with_write, &[1]u8{unitchar});

        if (alignment == .left)
            writeAlignment(with_write, int, digits_max);
    }
};

pub const Unit = enum {
    percent,
    cpu_percent,
    kilo,
    mega,
    giga,
    tera,
    si_one,
    si_kilo,
    si_mega,
    si_giga,
    si_tera,
};

pub const NumUnit = struct {
    val: F5608,
    unit: Unit,

    pub fn write(
        self: @This(),
        with_write: anytype,
        alignment: typ.Alignment,
        precision: u8,
    ) void {
        var p = precision;
        const digits_max: u8 = switch (self.unit) {
            .percent, .si_kilo, .si_mega, .si_giga, .si_tera => 3,
            .cpu_percent, .kilo, .mega, .giga, .tera => 4,
            .si_one => blk: {
                p = 0;
                break :blk @as(u8, 4) + @intFromBool(precision != 0) + precision;
            },
        };
        self.val.write(with_write, digits_max, alignment, p, switch (self.unit) {
            .percent, .cpu_percent => '%',
            .kilo => 'K',
            .mega => 'M',
            .giga => 'G',
            .tera => 'T',
            .si_one => '\x00',
            .si_kilo => 'k',
            .si_mega => 'm',
            .si_giga => 'g',
            .si_tera => 't',
        });
    }
};

pub fn SizeKb(value: u64) NumUnit {
    const KB4 = 4096;
    const MB4 = 4096 * 1024;
    const GB4 = 4096 * 1024 * 1024;

    return switch (value) {
        0...KB4 - 1 => .{
            .val = F5608.init(value),
            .unit = .kilo,
        },
        KB4...MB4 - 1 => .{
            .val = F5608.init(value).div(1024),
            .unit = .mega,
        },
        MB4...GB4 - 1 => .{
            .val = F5608.init(value).div(1024 * 1024),
            .unit = .giga,
        },
        else => .{
            .val = F5608.init(value).div(1024 * 1024 * 1024),
            .unit = .tera,
        },
    };
}

pub fn Percent(value: u64, total: u64) NumUnit {
    return .{ .val = F5608.init(value * 100).div(total), .unit = .percent };
}

pub fn UnitSI(value: u64) NumUnit {
    const K = 1000;
    const M = 1000 * 1000;
    const G = 1000 * 1000 * 1000;
    const T = 1000 * 1000 * 1000 * 1000;

    return switch (value) {
        0...K - 1 => .{ .val = F5608.init(value), .unit = .si_one },
        K...M - 1 => .{ .val = F5608.init(value).div(K), .unit = .si_kilo },
        M...G - 1 => .{ .val = F5608.init(value).div(M), .unit = .si_mega },
        G...T - 1 => .{ .val = F5608.init(value).div(G), .unit = .si_giga },
        else => .{ .val = F5608.init(value).div(T), .unit = .si_tera },
    };
}

pub inline fn writeStr(with_write: anytype, str: []const u8) void {
    _ = with_write.write(str) catch {};
}

pub inline fn writeInt(writer: anytype, value: u64) void {
    fmt.formatInt(value, 10, .lower, .{}, writer) catch {};
}

pub inline fn writeIntOpts(writer: anytype, value: u64, options: fmt.FormatOptions) void {
    fmt.formatInt(value, 10, .lower, options, writer) catch {};
}

pub fn writeBlockStart(
    with_write: anytype,
    fg_color: ?*const [7]u8,
    bg_color: ?*const [7]u8,
) void {
    if (fg_color) |fg_hex| {
        writeStr(with_write,
            \\{"color":"
        );
        writeStr(with_write, fg_hex);
        if (bg_color) |bg_hex| {
            writeStr(with_write,
                \\","background":"
            );
            writeStr(with_write, bg_hex);
        }
        writeStr(with_write,
            \\","full_text":"
        );
    } else if (bg_color) |bg_hex| {
        writeStr(with_write,
            \\{"background":"
        );
        writeStr(with_write, bg_hex);
        writeStr(with_write,
            \\","full_text":"
        );
    } else {
        writeStr(with_write,
            \\{"full_text":"
        );
    }
}

pub fn writeBlockEnd_GetWritten(fbs: anytype) []const u8 {
    const endstr = "\"},";
    const nwritten = fbs.write(endstr) catch |e| switch (e) {
        error.NoSpaceLeft => @as(usize, 0),
    };
    if (nwritten < endstr.len) {
        const seekamt: comptime_int = "...".len + endstr.len;
        fbs.seekBy(-seekamt) catch unreachable;
        _ = fbs.write("...") catch unreachable;
        _ = fbs.write(endstr) catch unreachable;
    }
    return fbs.getWritten();
}

// == LOGGING =================================================================

var bss_mem: [512]u8 = undefined;

fn makeMsg(comptime format: []const u8, args: anytype) []const u8 {
    return fmt.bufPrint(&bss_mem, format, args) catch return &bss_mem;
}

const Log = struct {
    file: ?fs.File,

    pub fn log(self: @This(), msg: []const u8) void {
        writeStr(io.getStdErr(), msg);
        if (self.file) |f| writeStr(f, msg);
    }

    pub fn close(self: @This()) void {
        if (self.file) |f| f.close();
    }
};

fn openLog() Log {
    const file = fs.cwd().createFileZ("/tmp/ziew.log", .{ .truncate = false });
    if (file) |f| {
        f.seekFromEnd(0) catch {};
    } else |e| switch (e) {
        error.AccessDenied => writeStr(
            io.getStdErr(),
            "open: /tmp/ziew.log: probably sticky, only author can modify\n",
        ),
        else => @panic(makeMsg("openLog: {s}", .{@errorName(e)})),
    }
    return .{ .file = file catch null };
}

pub fn fatal(strings: []const []const u8) noreturn {
    @setCold(true);
    const log = openLog();
    defer log.close();
    log.log("fatal: ");
    for (strings) |s| log.log(s);
    log.log("\n");
    linux.exit(1);
}

// inline to avoid comptime duplication
pub inline fn fatalFmt(comptime format: []const u8, args: anytype) noreturn {
    @setCold(true);
    const log = openLog();
    defer log.close();
    log.log(makeMsg("fatal: " ++ format ++ "\n", args));
    linux.exit(1);
}

pub fn fatalPos(strings: []const []const u8, err_pos: usize) noreturn {
    @setCold(true);
    const log = openLog();
    defer log.close();
    log.log("fatal: ");
    for (strings) |s| log.log(s);
    log.log("\n");
    var end = "fatal: ".len + err_pos;
    if (end > bss_mem.len) end = bss_mem.len;
    @memset(bss_mem[0..end], ' ');
    log.log(bss_mem[0..end]);
    log.log("^\n");
    linux.exit(1);
}

pub fn warn(strings: []const []const u8) void {
    @setCold(true);
    const log = openLog();
    defer log.close();
    log.log("warning: ");
    for (strings) |s| log.log(s);
    log.log("\n");
}

// == MISC ====================================================================

pub fn repr(str: ?[]const u8) void {
    const stderr = io.getStdErr().writer();
    if (str) |s| {
        std.zig.fmtEscapes(s).format("", .{}, stderr) catch {};
        writeStr(stderr, "\n");
    } else {
        writeStr(stderr, "<null>\n");
    }
}

pub fn unsafeAtou64(buf: []const u8) u64 {
    var r: u64 = buf[0] & 0x0f;
    for (buf[1..]) |ch| r = r * 10 + (ch & 0x0f);
    return r;
}

pub inline fn atou64ForwardUntil(
    buf: []const u8,
    i: *usize,
    comptime char: u8,
) u64 {
    var j = i.*;

    var r: u64 = buf[j] & 0x0f;
    j += 1;
    while (buf[j] != char) : (j += 1)
        r = r * 10 + (buf[j] & 0x0f);

    i.* = j;
    return r;
}

pub inline fn atou64BackwardUntil(
    buf: []const u8,
    i: *usize,
    comptime char: u8,
) u64 {
    var j = i.*;

    var unitpos_mul: u64 = 1;
    var r: u64 = 0;
    while (buf[j] != char) : (j -= 1) {
        r += (buf[j] & 0x0f) * unitpos_mul;
        unitpos_mul *= 10;
    }
    i.* = j;
    return r;
}

pub fn zeroTerminate(dest: []u8, src: []const u8) ?[:0]const u8 {
    if (src.len >= dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return dest[0..src.len :0];
}

pub fn skipSpacesTabs(str: []const u8, pos: usize) ?usize {
    return mem.indexOfNonePos(u8, str, pos, " \t");
}
