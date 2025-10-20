const std = @import("std");
const fs = std.fs;
const meta = std.meta;
const simd = std.simd;
const zig = std.zig;

pub fn repr(str: ?[]const u8) void {
    var writer = fs.File.stderr().writer(&.{});
    const stderr = &writer.interface;

    if (str) |s| {
        zig.stringEscape(s, stderr) catch {};
        _ = stderr.write("\n") catch {};
    } else {
        _ = stderr.write("<null>\n") catch {};
    }
}

pub fn trimWhitespace(str: []const u8) []const u8 {
    // This is the smallest (in terms of code size)
    // whitespace trimming loop I could come up with.
    var a: usize = 0;
    var b: usize = str.len;
    var t: usize = 0;
    while (a < b and t != b - a) {
        t = b - a;
        a += @intFromBool(str[a] <= ' ');
        b -= @intFromBool(str[b - 1] <= ' ');
    }
    return str[a..b];
}

pub inline fn atou(comptime T: type, buf: []const u8) T {
    var r: T = buf[0] & 0x0f;
    for (buf[1..]) |ch| r = r * 10 + (ch & 0x0f);
    return r;
}

pub inline fn atou64ForwardUntil(
    buf: []const u8,
    i: usize,
    comptime char: u8,
) struct { u64, usize } {
    var j = i;
    var r: u64 = 0;
    while (buf[j] != char) : (j += 1) {
        r = r * 10 + (buf[j] & 0x0f);
    }
    return .{ r, j };
}

pub inline fn atou64By8ForwardUntil(
    buf: []const u8,
    i: usize,
    comptime char: u8,
) struct { u64, usize } {
    const V = @Vector(8, u8);
    const exp10: [16]u32 = .{
        100_000_000, 10_000_000, 1_000_000, 100_000,
        10_000,      1_000,      100,       10,
        1,           0,          0,         0,
        0,           0,          0,         0,
    };
    var j = i;
    var r: u64 = 0;
    while (true) {
        const block: V = buf[j..][0..8].*;
        const digits = block & @as(V, @splat(0x0f));
        const mask: u8 = @bitCast(block == @as(V, @splat(char)));
        const len: u8 = @ctz(mask);
        r *= exp10[8 - len];
        r += @reduce(.Add, digits * exp10[1 + 8 - len ..][0..8].*);
        j += len;
        if (len != 8 or buf[j] == char) break;
    }
    return .{ r, j };
}

pub inline fn atou64ForwardUntilOrEOF(
    buf: []const u8,
    i: usize,
    comptime char: u8,
) struct { u64, usize } {
    var j = i;
    var r: u64 = 0;
    while (j < buf.len and buf[j] != char) : (j += 1) {
        r = r * 10 + (buf[j] & 0x0f);
    }
    return .{ r, j };
}

pub inline fn atou64BackwardUntil(
    buf: []const u8,
    i: usize,
    comptime char: u8,
) struct { u64, usize } {
    var j = i;
    var mul: u64 = 1;
    var r: u64 = 0;
    while (buf[j] != char) : (j -= 1) {
        r += (buf[j] & 0x0f) * mul;
        mul *= 10;
    }
    return .{ r, j };
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
            while (i < len & ~@as(usize, BlockSize - 1)) : (i += BlockSize) {
                const block: Block = self.buf[i..][0..BlockSize].*;
                const mask = block == @as(Block, @splat(findme));
                if (@reduce(.Or, mask)) {
                    self.bits = @bitCast(mask);
                    return self.nextBit(i);
                }
            }
            while (i < len) : (i += 1) {
                if (self.buf[i] == findme) {
                    self.i = i + 1;
                    return i;
                }
            }
            self.i = len;
            return null;
        }
    };
}
