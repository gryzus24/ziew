const std = @import("std");
const iou = @import("io.zig");
const fs = std.fs;
const linux = std.os.linux;

pub const Log = struct {
    fd: linux.fd_t,

    pub const nofile: Log = .{ .fd = -1 };

    pub fn open() Log {
        const path = "/tmp/ziew.log";
        const file = fs.cwd().createFileZ(path, .{ .truncate = false }) catch |e| switch (e) {
            error.AccessDenied => {
                _ = iou.sys_write(2, "open: " ++ path ++ ": probably sticky, only author can modify\n");
                return .nofile;
            },
            else => {
                _ = iou.sys_write(2, "open: " ++ path ++ ": ");
                _ = iou.sys_write(2, @errorName(e));
                _ = iou.sys_write(2, "\n");
                linux.exit(1);
            },
        };
        file.seekFromEnd(0) catch {};
        return .{ .fd = file.handle };
    }

    pub fn log(self: @This(), str: []const u8) void {
        _ = iou.sys_write(2, str);
        if (self.fd != -1)
            _ = iou.sys_write(self.fd, str);
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
