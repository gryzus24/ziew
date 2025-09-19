const std = @import("std");
const utl = @import("util.zig");
const fs = std.fs;
const linux = std.os.linux;

pub const Log = struct {
    fd: linux.fd_t,

    pub const nofile: Log = .{ .fd = -1 };

    pub fn open() Log {
        const path = "/tmp/ziew.log";
        const file = fs.cwd().createFileZ(path, .{ .truncate = false }) catch |e| switch (e) {
            error.AccessDenied => {
                utl.fdWrite(2, "open: " ++ path ++ ": probably sticky, only author can modify\n");
                return .nofile;
            },
            else => {
                utl.fdWrite(2, "open: " ++ path ++ ": ");
                utl.fdWrite(2, @errorName(e));
                utl.fdWrite(2, "\n");
                linux.exit(1);
            },
        };
        file.seekFromEnd(0) catch {};
        return .{ .fd = file.handle };
    }

    pub fn log(self: @This(), s: []const u8) void {
        utl.fdWrite(2, s);
        if (self.fd != -1)
            utl.fdWrite(self.fd, s);
    }

    pub fn close(self: @This()) void {
        if (self.fd != -1)
            _ = linux.close(self.fd);
    }
};

pub fn fatal(strings: []const []const u8) noreturn {
    @branchHint(.cold);
    const log: Log = .open();
    log.log("fatal: ");
    for (strings) |s| log.log(s);
    log.log("\n");
    linux.exit(1);
}

pub fn warn(strings: []const []const u8) void {
    @branchHint(.cold);
    const log: Log = .open();
    defer log.close();
    log.log("warning: ");
    for (strings) |s| log.log(s);
    log.log("\n");
}
