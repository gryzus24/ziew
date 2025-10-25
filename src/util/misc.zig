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

    const r, _ = ustr.atou64ForwardUntil(&buf, i, '\n');
    return @min(r + 1, NR_POSSIBLE_CPUS_MAX);
}

pub inline fn nrDigits(n: u64) u8 {
    var r = 1 +
        @as(u8, @intFromBool(n >= 10)) +
        @as(u8, @intFromBool(n >= 100)) +
        @as(u8, @intFromBool(n >= 1000)) +
        @as(u8, @intFromBool(n >= 10000));
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

// zig fmt: off
pub fn gcd(n: u32, m: u32) u32 {
    var a, var b = .{ n, m };
    if (a == 0 or b == 0) return @max(a, b);
    while (true) {
        a %= b; if (a == 0) return b;
        b %= a; if (b == 0) return a;
    }
}
// zig fmt: on
