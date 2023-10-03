const std = @import("std");
const cfg = @import("config.zig");
const fmt = std.fmt;
const io = std.io;
const os = std.os;

pub const c = @cImport({
    @cInclude("sys/statfs.h");
    @cInclude("time.h");
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

pub inline fn writeStr(with_write: anytype, str: []const u8) void {
    _ = with_write.write(str) catch {};
}

pub inline fn writeInt(writer: anytype, value: u64) void {
    fmt.formatInt(value, 10, .lower, .{}, writer) catch {};
}

pub inline fn writeFloat(writer: anytype, value: f64, precision: u8) void {
    fmt.formatFloatDecimal(value, .{ .precision = precision }, writer) catch {};
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

pub fn checkColor(value: f64, colors: []const cfg.Color) ?*const [7]u8 {
    var result: ?*const [7]u8 = null;
    for (colors) |*color| {
        if (value >= @as(f64, @floatFromInt(color.thresh))) {
            result = &color.hex;
        } else {
            break;
        }
    }
    return result;
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

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    @setCold(true);
    var buf: [512]u8 = undefined;
    out: {
        const msg = fmt.bufPrint(
            &buf,
            "fatal: " ++ format ++ "\n",
            args,
        ) catch break :out;
        _ = io.getStdErr().write(msg) catch break :out;
    }
    os.exit(1);
}

pub fn fatalPos(comptime format: []const u8, args: anytype, errpos: usize) noreturn {
    @setCold(true);
    var buf: [512]u8 = undefined;
    const stderr = io.getStdErr();
    out: {
        const msg = fmt.bufPrint(
            &buf,
            "fatal: " ++ format ++ "\n",
            args,
        ) catch break :out;
        _ = stderr.write(msg) catch break :out;
        for (0.."fatal: ".len + errpos) |_| {
            _ = stderr.write(" ") catch break :out;
        }
        _ = stderr.write("^\n") catch break :out;
    }
    os.exit(1);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    @setCold(true);
    var buf: [512]u8 = undefined;
    out: {
        const msg = fmt.bufPrint(
            &buf,
            "warning: " ++ format ++ "\n",
            args,
        ) catch break :out;
        _ = io.getStdErr().write(msg) catch break :out;
    }
}
