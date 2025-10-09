const std = @import("std");
const uio = @import("io.zig");
const ustr = @import("str.zig");

const linux = std.os.linux;

pub const NR_POSSIBLE_CPUS_MAX = 64;

pub fn nrPossibleCpus() u32 {
    const path = "/sys/devices/system/cpu/possible";
    const fd = uio.open0(path) catch return 0;
    defer uio.close(fd);

    var buf: [16]u8 = undefined;
    const nr_read = uio.pread(fd, &buf, 0) catch return 0;

    if (nr_read < 2) return 0;
    var i = nr_read - 2;
    while (i > 0 and buf[i] != '-') : (i -= 1) {}
    if (i > 0) i += 1;

    const r: u32 = @intCast(ustr.atou64ForwardUntil(&buf, &i, '\n') + 1);
    return @min(r, NR_POSSIBLE_CPUS_MAX);
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
