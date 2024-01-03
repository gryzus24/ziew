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

pub const NumUnit = struct {
    val: f64,
    unit: u8,
};

pub const BYTES_IN_4K = 4096;
pub const BYTES_IN_4M = 4096 * 1024;
pub const BYTES_IN_4G = 4096 * 1024 * 1024;

pub fn kbToHuman(value: u64) NumUnit {
    const fvalue: f64 = @floatFromInt(value);
    return switch (value) {
        0...BYTES_IN_4K - 1 => .{
            .val = fvalue,
            .unit = 'K',
        },
        BYTES_IN_4K...BYTES_IN_4M - 1 => .{
            .val = fvalue / 1024,
            .unit = 'M',
        },
        BYTES_IN_4M...BYTES_IN_4G - 1 => .{
            .val = fvalue / 1024 / 1024,
            .unit = 'G',
        },
        else => .{
            .val = fvalue / 1024 / 1024 / 1024,
            .unit = 'T',
        },
    };
}

pub fn percentOf(value: u64, total: u64) NumUnit {
    const fvalue: f64 = @floatFromInt(value);
    const ftotal: f64 = @floatFromInt(total);
    return .{ .val = fvalue / ftotal * 100, .unit = '%' };
}

pub fn zeroTerminate(dest: []u8, src: []const u8) ?[:0]const u8 {
    if (src.len >= dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return dest[0..src.len :0];
}

pub inline fn writeStr(with_write: anytype, str: []const u8) void {
    _ = with_write.write(str) catch {};
}

pub inline fn writeInt(writer: anytype, value: u64) void {
    fmt.formatInt(value, 10, .lower, .{}, writer) catch {};
}

pub inline fn writeFloat(writer: anytype, value: f64, precision: u8) void {
    if (precision == 0) {
        writeInt(writer, @intFromFloat(@round(value)));
    } else {
        fmt.formatFloatDecimal(value, .{ .precision = precision }, writer) catch {};
    }
}

pub const PRECISION_ROUND_EPS: [10]f64 = .{
    0.5 / 1.0,
    0.5 / 10.0,
    0.5 / 100.0,
    0.5 / 1000.0,
    0.5 / 10000.0,
    0.5 / 100000.0,
    0.5 / 1000000.0,
    0.5 / 10000000.0,
    0.5 / 100000000.0,
    0.5 / 1000000000.0,
};

pub const AlignmentValueType = enum { percent, size };

pub fn writeAlignment(
    with_write: anytype,
    value_type: AlignmentValueType,
    value: f64,
    precision: u8,
) void {
    const spaces: [3]u8 = .{ ' ', ' ', ' ' };
    const eps = PRECISION_ROUND_EPS[precision];

    const len: u2 = switch (value_type) {
        .percent => blk: {
            if (value < 10 - eps) {
                break :blk 2;
            } else if (value < 100 - eps) {
                break :blk 1;
            } else {
                break :blk 0;
            }
        },
        .size => blk: {
            if (value < 10 - eps) {
                break :blk 3;
            } else if (value < 100 - eps) {
                break :blk 2;
            } else if (value < 1000 - eps) {
                break :blk 1;
            } else {
                break :blk 0;
            }
        },
    };
    writeStr(with_write, spaces[0..len]);
}

pub fn writeNumUnit(
    with_write: anytype,
    nu: NumUnit,
    alignment: cfg.Alignment,
    precision: u8,
) void {
    const value_type: AlignmentValueType = if (nu.unit == '%') .percent else .size;

    if (alignment == .right)
        writeAlignment(with_write, value_type, nu.val, precision);

    writeFloat(with_write, nu.val, precision);
    writeStr(with_write, &[1]u8{nu.unit});

    if (alignment == .left)
        writeAlignment(with_write, value_type, nu.val, precision);
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
    writeStr(fbs,
        \\"},
    );
    const ret = fbs.getWritten();
    fbs.reset();
    return ret;
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
    const log = openLog();
    defer log.close();
    log.log("fatal: ");
    for (strings) |s| log.log(s);
    log.log("\n");
    os.exit(1);
}

pub fn fatalFmt(comptime format: []const u8, args: anytype) noreturn {
    const log = openLog();
    defer log.close();
    log.log(makeMsg("fatal: " ++ format ++ "\n", args));
    os.exit(1);
}

pub fn fatalPos(strings: []const []const u8, errpos: usize) noreturn {
    const log = openLog();
    defer log.close();
    log.log("fatal: ");
    for (strings) |s| log.log(s);
    log.log("\n");
    @memset(bss_mem[0 .. "fatal: ".len + errpos], ' ');
    log.log(bss_mem[0 .. "fatal: ".len + errpos]);
    log.log("^\n");
    os.exit(1);
}

pub fn warn(strings: []const []const u8) void {
    const log = openLog();
    defer log.close();
    log.log("warning: ");
    for (strings) |s| log.log(s);
    log.log("\n");
}

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
    var r: u64 = buf[0] - '0';
    for (buf[1..]) |ch| {
        r *= 10;
        r += ch - '0';
    }
    return r;
}
