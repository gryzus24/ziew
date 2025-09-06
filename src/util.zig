const std = @import("std");
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

pub inline fn writeInt(writer: *io.Writer, value: u64) void {
    writer.printIntAny(value, 10, .lower, .{}) catch {};
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

pub fn writeBlockBeg(
    writer: *io.Writer,
    fg_color: ?*const [7]u8,
    bg_color: ?*const [7]u8,
) void {
    // zig fmt: off
    const i: u2 = (
        @as(u2, @intFromBool(fg_color != null)) +
        @as(u2, @intFromBool(bg_color != null)) * 2);
    // zig fmt: on

    var header = BLOCK_HEADERS[i];
    switch (i) {
        0 => {},
        1 => {
            @memcpy(header[11..17], fg_color.?[1..]);
        },
        2 => {
            @memcpy(header[16..22], bg_color.?[1..]);
        },
        3 => {
            @memcpy(header[11..17], fg_color.?[1..]);
            @memcpy(header[34..40], bg_color.?[1..]);
        },
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

// == LOGGING =================================================================

pub var bss: [512]u8 = undefined;

const Log = struct {
    fd: linux.fd_t = -1,

    pub fn log(self: @This(), s: []const u8) void {
        fdWrite(2, s);
        if (self.fd != -1) fdWrite(self.fd, s);
    }

    pub fn close(self: @This()) void {
        if (self.fd != -1) _ = linux.close(self.fd);
    }
};

pub fn bssPrint(comptime format: []const u8, args: anytype) []const u8 {
    var w: io.Writer = .fixed(&bss);
    w.print(format, args) catch return &.{};
    return w.buffered();
}

pub fn openLog() Log {
    const path = "/tmp/ziew.log";
    const file = fs.cwd().createFileZ(path, .{ .truncate = false }) catch |e| switch (e) {
        error.AccessDenied => {
            fdWrite(2, "open: " ++ path ++ ": probably sticky, only author can modify\n");
            return .{};
        },
        else => @panic(bssPrint("openLog: {s}", .{@errorName(e)})),
    };

    file.seekFromEnd(0) catch {};
    return .{ .fd = file.handle };
}

pub fn fatal(strings: []const []const u8) noreturn {
    @branchHint(.cold);
    const log = openLog();
    log.log("fatal: ");
    for (strings) |s| log.log(s);
    log.log("\n");
    linux.exit(1);
}

// inline to avoid comptime duplication
pub inline fn fatalFmt(comptime format: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    const log = openLog();
    log.log(bssPrint("fatal: " ++ format ++ "\n", args));
    linux.exit(1);
}

pub fn warn(strings: []const []const u8) void {
    @branchHint(.cold);
    const log = openLog();
    defer log.close();
    log.log("warning: ");
    for (strings) |s| log.log(s);
    log.log("\n");
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

pub fn zeroTerminate(dest: []u8, src: []const u8) ?[:0]const u8 {
    if (src.len >= dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return dest[0..src.len :0];
}

pub fn skipSpacesTabs(str: []const u8, pos: usize) ?usize {
    return mem.indexOfNonePos(u8, str, pos, " \t");
}

pub fn nrDigits(n: u64) u5 {
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

pub fn calc(new: u64, old: u64, diff: bool) u64 {
    return if (diff) new - old else new;
}
