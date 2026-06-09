const std = @import("std");

const uio = @import("util/io.zig");
const ustr = @import("util/str.zig");

const linux = std.os.linux;

// == private =================================================================

fn openLogStrings(prefix: []const u8, strings: []const []const u8) Log {
    const log: Log = .open(.default);
    log.log(prefix);
    for (strings) |s| log.log(s);
    return log;
}

// == public ==================================================================

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
            ret.file = uio.openCWA(path, 0o644) catch |e| switch (e) {
                error.AccessDenied => blk: {
                    _ = uio.sys_write(ret.stream, "open: " ++ path ++ ": AccessDenied: ");
                    _ = uio.sys_write(ret.stream, "may be sticky - only author can modify\n");
                    break :blk -1;
                },
                else => {
                    _ = uio.sys_write(ret.stream, "open: " ++ path ++ ": ");
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

pub fn fatal(strings: []const []const u8) noreturn {
    @branchHint(.cold);
    const log = openLogStrings("fatal: ", strings);
    log.log("\n");
    linux.exit(1);
}

pub fn fatalSys(strings: []const []const u8, sysret: isize) noreturn {
    @branchHint(.cold);
    std.debug.assert(sysret < 0);

    const log = openLogStrings("fatal: ", strings);
    var buf: ["4095\n".len]u8 = undefined;

    const n = ustr.unsafeU64toa(
        buf[0 .. buf.len - 1],
        @as(u64, @intCast(-sysret)) & 0x0fff,
    );
    buf[buf.len - 1] = '\n';

    log.log(buf[buf.len - n - 1 ..]);
    linux.exit(1);
}

pub fn warn(strings: []const []const u8) void {
    @branchHint(.cold);
    const log = openLogStrings("warning: ", strings);
    defer log.close();
    log.log("\n");
}
