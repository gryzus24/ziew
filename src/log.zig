const std = @import("std");

const uio = @import("util/io.zig");
const ustr = @import("util/str.zig");

const linux = std.os.linux;

// == private =================================================================

fn openLogStrings(prefix: []const u8, strings: []const []const u8) Log {
    const log: Log = .open();
    log.log(prefix);
    for (strings) |s| log.log(s);
    return log;
}

// == public ==================================================================

pub const Log = struct {
    fd: linux.fd_t,

    pub const nofile: Log = .{ .fd = -1 };

    pub fn open() Log {
        const path = "/tmp/ziew.log";
        const fd = uio.openCWA(path, 0o644) catch |e| switch (e) {
            error.AccessDenied => {
                _ = uio.sys_write(2, "open: " ++ path ++ ": AccessDenied: ");
                _ = uio.sys_write(2, "may be sticky - only author can modify\n");
                return .nofile;
            },
            else => {
                _ = uio.sys_write(2, "open: " ++ path ++ ": ");
                _ = uio.sys_write(2, @errorName(e));
                _ = uio.sys_write(2, "\n");
                linux.exit(1);
            },
        };
        return .{ .fd = fd };
    }

    pub fn log(self: @This(), str: []const u8) void {
        _ = uio.sys_write(2, str);
        if (self.fd != -1)
            _ = uio.sys_write(self.fd, str);
    }

    pub fn close(self: @This()) void {
        if (self.fd != -1)
            uio.close(self.fd);
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
    var buf: [8]u8 = undefined;

    var pos = ustr.unsafeU64toa(&buf, @as(u64, @intCast(-sysret)) & 0x0fff);
    @memmove(buf[0..pos], buf[buf.len - pos ..]);
    buf[pos] = '\n';
    pos += 1;

    log.log(buf[0..pos]);
    linux.exit(1);
}

pub fn warn(strings: []const []const u8) void {
    @branchHint(.cold);
    const log = openLogStrings("warning: ", strings);
    defer log.close();
    log.log("\n");
}
