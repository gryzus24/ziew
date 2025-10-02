const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const linux = std.os.linux;
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;
const simd = std.simd;
const zig = std.zig;

// zig fmt: off
pub const c = @cImport({
    @cInclude("errno.h");      // errno constants
    @cInclude("sys/statfs.h"); // statfs()
    @cInclude("time.h");       // strftime() etc.
});
// zig fmt: on

pub inline fn fdWrite(fd: linux.fd_t, s: []const u8) void {
    _ = linux.write(fd, s.ptr, s.len);
}

pub inline fn fdWriteV(fd: linux.fd_t, vs: anytype) void {
    const len = @typeInfo(@TypeOf(vs)).@"struct".fields.len;
    var iovs: [len]posix.iovec_const = undefined;
    inline for (vs, 0..) |s, i| iovs[i] = .{ .base = s.ptr, .len = s.len };
    _ = linux.writev(fd, &iovs, iovs.len);
}

pub inline fn writeStr(writer: *io.Writer, s: []const u8) void {
    const n = @min(s.len, writer.unusedCapacityLen());
    const dst = writer.buffer[writer.end..];
    for (0..n) |i| dst[i] = s[i];
    writer.end += n;
}

pub fn writeWidgetBeg(writer: *io.Writer, fg: color.Hex, bg: color.Hex) void {
    if (typ.WIDGET_BUF_MAX < 64)
        @compileError("typ.WIDGET_BUF_MAX < 64");

    const dst = writer.buffer[writer.end..];
    switch (fg.use | @shlExact(bg.use, 1)) {
        0 => {
            const str = "{\"full_text\":\"";
            dst[0..16].* = (str ++ .{ undefined, undefined }).*;
            writer.end += str.len;
        },
        1 => {
            const str =
                \\{"color":"#XXXXXX","full_text":"
            ;
            dst[0..32].* = str.*;
            dst[11..17].* = fg.hex;
            writer.end += str.len;
        },
        2 => {
            const str =
                \\{"background":"#XXXXXX","full_text":"
            ;
            dst[0..37].* = str.*;
            dst[16..22].* = bg.hex;
            writer.end += str.len;
        },
        3 => {
            const str =
                \\{"color":"#XXXXXX","background":"#XXXXXX","full_text":"
            ;
            dst[0..55].* = str.*;
            dst[11..17].* = fg.hex;
            dst[34..40].* = bg.hex;
            writer.end += str.len;
        },
        else => unreachable,
    }
}

pub fn writeWidgetEnd(writer: *io.Writer) []const u8 {
    const endstr = "\"},";
    const cap = writer.unusedCapacityLen();
    const buffer = writer.buffer;
    const end = writer.end;

    if (endstr.len <= cap) {
        @branchHint(.likely);
        buffer[end..][0..3].* = endstr.*;
        writer.end = end + 3;
        return buffer[0 .. end + 3];
    }

    buffer[buffer.len - 6 ..][0..6].* = ("…" ++ endstr).*;
    writer.end = buffer.len;
    return buffer;
}

// == MISC ====================================================================

pub fn repr(str: ?[]const u8) void {
    var writer = fs.File.stderr().writer(&.{});
    const stderr = &writer.interface;

    if (str) |s| {
        zig.stringEscape(s, stderr) catch {};
        writeStr(stderr, "\n");
    } else {
        writeStr(stderr, "<null>\n");
    }
}

pub inline fn unsafeAtou64(buf: []const u8) u64 {
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

pub inline fn atou64ForwardUntilOrEOF(
    buf: []const u8,
    i: *usize,
    comptime char: u8,
) u64 {
    var j = i.*;

    var r: u64 = 0;
    while (j < buf.len and buf[j] != char) : (j += 1)
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

    var mul: u64 = 1;
    var r: u64 = 0;
    while (buf[j] != char) : (j -= 1) {
        r += (buf[j] & 0x0f) * mul;
        mul *= 10;
    }
    i.* = j;
    return r;
}

pub fn atou32V9Back(buf: []const u8) u32 {
    const Block = @Vector(8, u32);

    const exp: Block = .{
        100_000_000, 10_000_000, 1_000_000,
        100_000,     10_000,     1_000,
        100,         10,
    };
    const u = buf[buf.len - 1];
    const block: Block = buf[buf.len - 9 ..][0..8].*;
    const r = (block & @as(Block, @splat(0x0f))) * exp;
    return @reduce(.Add, r) + (u & 0x0f);
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
    const r: u32 = @intCast(atou64ForwardUntil(&buf, &i, '\n') + 1);
    return @min(r, NR_POSSIBLE_CPUS_MAX);
}

pub fn digits2_lut(n: u64) [2]u8 {
    return "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"[n * 2 ..][0..2].*;
}

pub fn unsafeU64toa(dst: []u8, n: u64) usize {
    var i = dst.len;
    var t = n;
    while (t >= 100) : (t /= 100) {
        i -= 2;
        dst[i..][0..2].* = digits2_lut(t % 100);
    }
    if (t < 10) {
        i -= 1;
        dst[i] = '0' | @as(u8, @intCast(t));
    } else {
        i -= 2;
        dst[i..][0..2].* = digits2_lut(t);
    }
    return dst.len - i;
}

// This is so naive and untweaked yet it benches faster than
// `mem.indexOfScalarPos` in a loop on random input and has
// a nice 20%/20% frontend/backend ratio in that scenario.
pub fn IndexIterator(comptime T: type, findme: T) type {
    return struct {
        buf: []const T,
        i: usize,
        bits: meta.Int(.unsigned, BlockSize),

        const BlockSize = @min(64, 2 * (simd.suggestVectorLength(T) orelse 8));
        const Block = @Vector(BlockSize, T);

        pub fn init(buf: []const T) @This() {
            return .{ .buf = buf, .i = 0, .bits = 0 };
        }

        inline fn nextBit(self: *@This(), i: usize) usize {
            const lsb = self.bits & (~self.bits + 1);
            const j = @ctz(self.bits);
            self.bits ^= lsb;
            self.i = i + @intFromBool(self.bits == 0) * @as(usize, BlockSize);
            return i + j;
        }

        pub fn next(self: *@This()) ?usize {
            var i = self.i;
            if (self.bits != 0)
                return self.nextBit(i);

            const len = self.buf.len;
            while (i < len & ~@as(usize, BlockSize - 1)) {
                const block: Block = self.buf[i..][0..BlockSize].*;
                const mask = block == @as(Block, @splat(findme));
                if (@reduce(.Or, mask)) {
                    self.bits = @bitCast(mask);
                    return self.nextBit(i);
                }
                i += BlockSize;
            }
            while (i < len) : (i += 1) {
                if (self.buf[i] == findme) {
                    self.i = i + 1;
                    return i;
                }
            }
            self.i = self.buf.len;
            return null;
        }
    };
}

pub const MultShft = struct {
    mult: u32,
    shft: u6,
};

// Completely unproven and off-the-cuff implementation of finding the "multiply
// and shift" combination for divisor constants.  The idea is to start at the
// lowest fraction that overshoots the "goal" fraction and refine the result by
// going over the multiplier and a precision shift in a nested binary search
// until the goal of "safe divisibility" is met.
//
// The number N is safely divisible if `(N * multiplier) >> shift` gives the
// same result as `N / d`.  If `N > dividend_max` the result MAY be inaccurate
// (initially off by one, but the error accrues).
//
// Not all divisors can be expressed in this way directly.  A sufficiently high
// divisibility goal may necessitate first dividing N to make sure no overflow
// occurs as the multiplier may exceed the 32 bits of precision afforded by
// upcasting u32s to u64s for calculations.  Compilers, when applying this kind
// of optimization, can do this automatically by emitting a `shr` instruction
// based on the knowledge of the divisor.  Unfortunately, handling these edge
// cases in code requires cooperation with the caller.
pub fn DivConstant(comptime d: u32, comptime dividend_max: comptime_int) MultShft {
    @setEvalBranchQuota(10_000);
    const DEBUG = false;

    if (d == 0) @compileError("-- you can't do that!");
    if (d == 1) return .{ .mult = 1, .shft = 0 }; // identity
    if (d & (d - 1) == 0) return .{ .mult = 1, .shft = @ctz(d) }; // power of two

    const target = 1.0 / @as(f64, d);

    var base: u5 = 0;
    inline for (2..32) |i| {
        if ((1 << i) > d) {
            base = i;
            break;
        }
    }

    var mult: u64 = 1;
    var prec: u6 = 0;

    while (true) {
        var steps = prec + 1;
        while (true) : (steps -= 1) {
            const f_mult: f64 = @floatFromInt(mult);
            const f_denom: f64 = @floatFromInt(@as(u64, 1) << base << prec);
            const ratio = f_mult / f_denom;
            const diff = target - ratio;

            const nr_safely_divisible = -(target / diff) - 1;
            if (nr_safely_divisible > dividend_max) {
                if (DEBUG) {
                    std.debug.print(
                        "\nd={:9} base={:2} prec={:2} mult={:10} safe={:10} ratio={}",
                        .{ d, base, prec, mult, nr_safely_divisible, ratio },
                    );
                }
                if (mult > ~@as(u32, 0))
                    @panic("-- multiplier could overflow!");

                return .{ .mult = @intCast(mult), .shft = base + prec };
            }
            if (steps == 0)
                break;

            const n = @as(u64, 1) << (steps - 1);
            if (diff > 0) {
                mult += n;
            } else {
                mult -= n;
            }
        }
        prec += 1;
    }
    unreachable;
}

pub inline fn cMultShiftDivMod(
    n: u64,
    comptime d: u32,
    comptime dividend_max: u32,
) struct { u64, u64 } {
    const ms = comptime DivConstant(d, dividend_max);
    const q = (n * ms.mult) >> ms.shft;
    const r = n - (q * d);
    return .{ q, r };
}

pub inline fn multShiftDivMod(n: u64, ms: MultShft, d: u32) struct { u64, u64 } {
    const q = (n * ms.mult) >> ms.shft;
    const r = n - (q * d);
    return .{ q, r };
}
