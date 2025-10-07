const std = @import("std");
const linux = std.os.linux;

// zig fmt: off
pub const c = @cImport({
    @cInclude("asm-generic/errno.h");
    @cInclude("sys/statfs.h");
    @cInclude("time.h");
});
// zig fmt: on

pub const struct_statfs = c.struct_statfs;
pub const struct_tm = c.struct_tm;

pub const localtime_r = c.localtime_r;
pub const strftime = c.strftime;

pub fn sys_statfs(path: [*:0]const u8, sfs: *struct_statfs) isize {
    return @bitCast(linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(sfs)));
}
