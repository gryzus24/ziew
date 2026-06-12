const std = @import("std");

const uio = @import("util/io.zig");
const ustr = @import("util/str.zig");

const linux = std.os.linux;

pub const Log = struct {
    stream: linux.fd_t,
    file: linux.fd_t,

    pub const Open = struct {
        o: u32,

        pub const stderr: Open = .{ .o = 1 };
        pub const file: Open = .{ .o = 2 };
        pub const default: Open = .{ .o = stderr.o | file.o };
    };

    pub fn open(mode: Open) Log {
        var ret: Log = .{ .stream = -1, .file = -1 };

        if (mode.o & Open.stderr.o != 0)
            ret.stream = 2;
        if (mode.o & Open.file.o != 0) {
            const path = "/tmp/ziew.log";
            const err_prefix = "open: " ++ path ++ ": ";

            ret.file = uio.openCWA(path, 0o644) catch |e| switch (e) {
                error.AccessDenied => blk: {
                    _ = uio.sys_write(ret.stream, err_prefix ++
                        "AccessDenied: may be sticky - only author can modify\n");
                    break :blk -1;
                },
                else => {
                    _ = uio.sys_write(ret.stream, err_prefix);
                    _ = uio.sys_write(ret.stream, @errorName(e));
                    _ = uio.sys_write(ret.stream, "\n");
                    linux.exit(1);
                },
            };
        }
        return ret;
    }

    pub fn log(self: @This(), str: []const u8) void {
        if (self.stream != -1) _ = uio.sys_write(self.stream, str);
        if (self.file != -1) _ = uio.sys_write(self.file, str);
    }

    pub fn close(self: @This()) void {
        if (self.file != -1) uio.close(self.file);
    }
};

pub fn logStrings(
    mode: Log.Open,
    first: ?[]const u8,
    inner: []const []const u8,
    last: ?[]const u8,
) void {
    const log: Log = .open(mode);
    defer log.close();
    if (first) |ok| log.log(ok);
    for (inner) |s| log.log(s);
    if (last) |ok| log.log(ok);
}

pub fn fatal(strings: []const []const u8) noreturn {
    @branchHint(.cold);
    logStrings(.default, "fatal: ", strings, "\n");
    linux.exit(1);
}

pub fn fatalSys(strings: []const []const u8, sysret: isize) noreturn {
    @branchHint(.cold);

    std.debug.assert(sysret < 0);
    const errno = @as(usize, @intCast(-sysret)) & 0x0fff;

    var buf: [5]u8 = .{ undefined, undefined, undefined, undefined, '\n' };
    const n = ustr.unsafeU64toa(buf[0 .. buf.len - 1], errno);

    logStrings(.default, "fatal: ", strings, buf[buf.len - n - 1 ..]);
    linux.exit(1);
}

pub fn warn(strings: []const []const u8) void {
    @branchHint(.cold);
    logStrings(.default, "warning: ", strings, "\n");
}
