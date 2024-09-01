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
