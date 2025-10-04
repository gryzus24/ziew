const std = @import("std");
const log = @import("log.zig");
const su = @import("str.zig");
const fs = std.fs;

pub const NR_POSSIBLE_CPUS_MAX = 64;

pub fn nrPossibleCpus() u32 {
    const path = "/sys/devices/system/cpu/possible";
    const file = fs.cwd().openFileZ(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return NR_POSSIBLE_CPUS_MAX,
        else => log.fatal(&.{ "open: ", path, ": ", @errorName(e) }),
    };
    defer file.close();

    var buf: [16]u8 = undefined;
    const nr_read = file.read(&buf) catch |e| {
        log.fatal(&.{ "read: ", @errorName(e) });
    };
    if (nr_read < 2) log.fatal(&.{"read: empty cpu/possible"});

    var i: usize = nr_read - 2;
    while (i > 0) : (i -= 1) {
        if (buf[i] == '-') {
            i += 1;
            break;
        }
    }
    const r: u32 = @intCast(su.atou64ForwardUntil(&buf, &i, '\n') + 1);
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
