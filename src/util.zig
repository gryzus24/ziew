const std = @import("std");
const cfg = @import("config.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const os = std.os;

pub const c = @cImport({
    @cInclude("errno.h"); // errno constants
    @cInclude("net/if.h"); // IFF_* definitions
    @cInclude("sys/ioctl.h"); // SIOCGIFADDR, SIOCGIFFLAGS definitions
    @cInclude("sys/statfs.h"); // statfs()
    @cInclude("time.h"); // strftime() etc.
});

fn writeAlignment(with_write: anytype, value: u64, maxpad: u8) void {
    const pad = maxpad -| @as(u8, switch (value) {
        0...9 => 1,
        10...99 => 2,
        100...999 => 3,
        else => 4,
    });
    writeStr(with_write, "    "[0..pad]);
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
                @compileError("FRAC_SHIFT too low to satisfy the rounding precision");
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

    pub const AlignmentValueType = enum(u8) { percent = 3, size = 4 };

    pub fn write(
        self: @This(),
        with_write: anytype,
        value_type: AlignmentValueType,
        alignment: cfg.Alignment,
        precision: u8,
    ) void {
        const rounded = self._round(precision);
        const int = rounded.whole();

        if (alignment == .right)
            writeAlignment(with_write, int, @intFromEnum(value_type));

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

        if (alignment == .left)
            writeAlignment(with_write, int, @intFromEnum(value_type));
    }
};

pub const NumUnit = struct {
    val: F5608,
    unit: u8,

    pub fn write(
        nu: @This(),
        with_write: anytype,
        alignment: cfg.Alignment,
        precision: u8,
    ) void {
        nu.val.write(
            with_write,
            if (nu.unit == '%') .percent else .size,
            alignment,
            precision,
        );
        writeStr(with_write, &[1]u8{nu.unit});
    }
};

pub fn kbToHuman(value: u64) NumUnit {
    const BYTES_IN_4K = 4096;
    const BYTES_IN_4M = 4096 * 1024;
    const BYTES_IN_4G = 4096 * 1024 * 1024;

    return switch (value) {
        0...BYTES_IN_4K - 1 => .{
            .val = F5608.init(value),
            .unit = 'K',
        },
        BYTES_IN_4K...BYTES_IN_4M - 1 => .{
            .val = F5608.init(value).div(1024),
            .unit = 'M',
        },
        BYTES_IN_4M...BYTES_IN_4G - 1 => .{
            .val = F5608.init(value).div(1024 * 1024),
            .unit = 'G',
        },
        else => .{
            .val = F5608.init(value).div(1024 * 1024 * 1024),
            .unit = 'T',
        },
    };
}

pub fn percentOf(value: u64, total: u64) NumUnit {
    return .{ .val = F5608.init(value * 100).div(total), .unit = '%' };
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
    const nwritten = fbs.write(endstr) catch |err| switch (err) {
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
    } else |err| switch (err) {
        error.AccessDenied => writeStr(
            io.getStdErr(),
            "open: /tmp/ziew.log: probably sticky, only author can modify\n",
        ),
        else => @panic(makeMsg("openLog: {s}", .{@errorName(err)})),
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
    os.exit(1);
}

// inline to avoid comptime duplication
pub inline fn fatalFmt(comptime format: []const u8, args: anytype) noreturn {
    @setCold(true);
    const log = openLog();
    defer log.close();
    log.log(makeMsg("fatal: " ++ format ++ "\n", args));
    os.exit(1);
}

pub fn fatalPos(strings: []const []const u8, errpos: usize) noreturn {
    @setCold(true);
    const log = openLog();
    defer log.close();
    log.log("fatal: ");
    for (strings) |s| log.log(s);
    log.log("\n");
    var errend = "fatal: ".len + errpos;
    if (errend > bss_mem.len) errend = bss_mem.len;
    @memset(bss_mem[0..errend], ' ');
    log.log(bss_mem[0..errend]);
    log.log("^\n");
    os.exit(1);
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

pub fn zeroTerminate(dest: []u8, src: []const u8) ?[:0]const u8 {
    if (src.len >= dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return dest[0..src.len :0];
}

pub fn skipChars(str: []const u8, chars: []const u8) usize {
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        for (chars) |ch| {
            if (str[i] == ch) break;
        } else {
            return i;
        }
    }
    return i;
}
