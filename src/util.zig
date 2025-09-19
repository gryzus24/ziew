const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const linux = std.os.linux;
const mem = std.mem;
const posix = std.posix;
const zig = std.zig;

// zig fmt: off
pub const c = @cImport({
    @cInclude("errno.h");      // errno constants
    @cInclude("sys/statfs.h"); // statfs()
    @cInclude("time.h");       // strftime() etc.
});
// zig fmt: on

pub inline fn fdWrite(fd: linux.fd_t, s: []const u8) void {
    _ = linux.write(fd, s.ptr, s.len);
}

pub inline fn fdWriteV(fd: linux.fd_t, vs: anytype) void {
    const len = @typeInfo(@TypeOf(vs)).@"struct".fields.len;
    var iovs: [len]posix.iovec_const = undefined;
    inline for (vs, 0..) |s, i| iovs[i] = .{ .base = s.ptr, .len = s.len };
    _ = linux.writev(fd, &iovs, iovs.len);
}

pub inline fn writeStr(writer: *io.Writer, s: []const u8) void {
    _ = writer.write(s) catch {};
}

const A =
    \\{"full_text":"
;
var NC_A = blk: {
    var w: [A.len]u8 = undefined;
    @memcpy(&w, A);
    break :blk w;
};

const B =
    \\{"color":"#XXXXXX","full_text":"
;
var FG_B = blk: {
    var w: [B.len]u8 = undefined;
    @memcpy(&w, B);
    break :blk w;
};

const C =
    \\{"background":"#XXXXXX","full_text":"
;
var BG_C = blk: {
    var w: [C.len]u8 = undefined;
    @memcpy(&w, C);
    break :blk w;
};

const D =
    \\{"color":"#XXXXXX","background":"#XXXXXX","full_text":"
;
var FGBG_D = blk: {
    var w: [D.len]u8 = undefined;
    @memcpy(&w, D);
    break :blk w;
};

var BLOCK_HEADERS: [4][]u8 = .{ &NC_A, &FG_B, &BG_C, &FGBG_D };

pub fn writeBlockBeg(writer: *io.Writer, fg: color.Hex, bg: color.Hex) void {
    const i = fg.use | (bg.use << 1);

    var header = BLOCK_HEADERS[i];
    switch (i) {
        0 => {},
        1 => {
            @memcpy(header[11..17], &fg.hex);
        },
        2 => {
            @memcpy(header[16..22], &bg.hex);
        },
        3 => {
            @memcpy(header[11..17], &fg.hex);
            @memcpy(header[34..40], &bg.hex);
        },
        else => unreachable,
    }
    writeStr(writer, header);
}

pub fn writeBlockEnd(writer: *io.Writer) []const u8 {
    const endstr = "\"},";
    const nr_written = writer.write(endstr) catch |e| switch (e) {
        error.WriteFailed => 0,
    };
    if (nr_written < endstr.len) {
        @branchHint(.unlikely);
        const undoamt: comptime_int = "...".len + endstr.len;
        writer.undo(undoamt);
        _ = writer.write("...") catch unreachable;
        _ = writer.write(endstr) catch unreachable;
    }
    return writer.buffered();
}

// == MISC ====================================================================

pub fn repr(str: ?[]const u8) void {
    var writer = fs.File.stderr().writer(&.{});
    const stderr = &writer.interface;

    if (str) |s| {
        zig.stringEscape(s, stderr) catch {};
        writeStr(stderr, "\n");
    } else {
        writeStr(stderr, "<null>\n");
    }
}

pub inline fn unsafeAtou64(buf: []const u8) u64 {
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

pub inline fn atou64ForwardUntilOrEOF(
    buf: []const u8,
    i: *usize,
    comptime char: u8,
) u64 {
    var j = i.*;

    var r: u64 = 0;
    while (j < buf.len and buf[j] != char) : (j += 1)
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

    var mul: u64 = 1;
    var r: u64 = 0;
    while (buf[j] != char) : (j -= 1) {
        r += (buf[j] & 0x0f) * mul;
        mul *= 10;
    }
    i.* = j;
    return r;
}

pub inline fn nrDigits(n: u64) u5 {
    var result: u5 = 1;
    var t = n;
    while (true) {
        if (t < 10) return result;
        if (t < 100) return result + 1;
        if (t < 1000) return result + 2;
        if (t < 10000) return result + 3;
        t /= 10000;
        result += 4;
    }
}

pub inline fn calc(new: u64, old: u64, diff: bool) u64 {
    return if (diff) new - old else new;
}

pub const NR_POSSIBLE_CPUS_MAX = 64;

pub fn nrPossibleCpus() u32 {
    const path = "/sys/devices/system/cpu/possible";
    const file = fs.cwd().openFileZ(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return NR_POSSIBLE_CPUS_MAX,
        else => log.fatal(&.{ "open: ", path, ": ", @errorName(e) }),
    };
    defer file.close();

    var buf: [16]u8 = undefined;
    const nr_read = file.read(&buf) catch |e| {
        log.fatal(&.{ "read: ", @errorName(e) });
    };
    if (nr_read < 2) log.fatal(&.{"read: empty cpu/possible"});

    var i: usize = nr_read - 2;
    while (i > 0) : (i -= 1) {
        if (buf[i] == '-') {
            i += 1;
            break;
        }
    }
    const r: u32 = @intCast(atou64ForwardUntil(&buf, &i, '\n') + 1);
    return @min(r, NR_POSSIBLE_CPUS_MAX);
}
