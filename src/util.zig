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
    const n = @min(s.len, writer.unusedCapacityLen());
    const dst = writer.buffer[writer.end..];
    for (0..n) |i| dst[i] = s[i];
    writer.end += n;
}

pub fn writeBlockBeg(writer: *io.Writer, fg: color.Hex, bg: color.Hex) void {
    if (typ.WIDGET_BUF_MAX < 64)
        @compileError("typ.WIDGET_BUF_MAX < 64");

    const dst = writer.buffer[writer.end..];
    switch (fg.use | (bg.use << 1)) {
        0 => {
            const str = "{\"full_text\":\"";
            dst[0..16].* = (str ++ .{ undefined, undefined }).*;
            writer.end += str.len;
        },
        1 => {
            const str =
                \\{"color":"#XXXXXX","full_text":"
            ;
            dst[0..32].* = str.*;
            dst[11..17].* = fg.hex;
            writer.end += str.len;
        },
        2 => {
            const str =
                \\{"background":"#XXXXXX","full_text":"
            ;
            dst[0..37].* = str.*;
            dst[16..22].* = bg.hex;
            writer.end += str.len;
        },
        3 => {
            const str =
                \\{"color":"#XXXXXX","background":"#XXXXXX","full_text":"
            ;
            dst[0..55].* = str.*;
            dst[11..17].* = fg.hex;
            dst[34..40].* = bg.hex;
            writer.end += str.len;
        },
        else => unreachable,
    }
}

pub inline fn writeBlockEnd(writer: *io.Writer) []const u8 {
    const endstr = "\"},";
    const cap = writer.unusedCapacityLen();
    const buffer = writer.buffer;
    const end = writer.end;

    if (endstr.len <= cap) {
        @branchHint(.likely);
        buffer[end..][0..3].* = endstr.*;
        writer.end = end + 3;
        return buffer[0 .. end + 3];
    }

    buffer[buffer.len - 6 ..][0..6].* = ("…" ++ endstr).*;
    writer.end = buffer.len;
    return buffer;
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

pub inline fn nrDigits(n: u64) u8 {
    // zig fmt: off
    var r = (
        1 +
        @as(u8, @intFromBool(n >= 10)) +
        @as(u8, @intFromBool(n >= 100)) +
        @as(u8, @intFromBool(n >= 1000)) +
        @as(u8, @intFromBool(n >= 10000))
    );
    // zig fmt: on

    if (r < 5) {
        @branchHint(.likely);
        return r;
    }

    var t = n / 10000;
    while (t >= 10) {
        t /= 10;
        r += 1;
    }
    return r;
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

pub fn digits2_lut(n: u64) [2]u8 {
    return "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"[n * 2 ..][0..2].*;
}

pub fn unsafeU64toa(dst: []u8, n: u64) void {
    var i = dst.len;
    var t = n;
    while (t >= 100) : (t /= 100) {
        i -= 2;
        dst[i..][0..2].* = digits2_lut(t % 100);
    }
    if (t < 10) {
        i -= 1;
        dst[i] = '0' | @as(u8, @intCast(t));
    } else {
        i -= 2;
        dst[i..][0..2].* = digits2_lut(t);
    }
}
