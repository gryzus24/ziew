const std = @import("std");
const simd = std.simd;

// Not necessarily whitespace, but it's
// fine if we can ignore the NUL byte.
pub fn isWhitespace(c: u8) bool {
    return c <= ' ';
}

pub fn trimWhitespace(str: []const u8) []const u8 {
    // This is the smallest (in terms of code size)
    // "whitespace" trimming loop I could come up with.
    var a: usize = 0;
    var b: usize = str.len;
    var t: usize = 0;
    while (a < b and t != b - a) {
        t = b - a;
        a += @intFromBool(isWhitespace(str[a]));
        b -= @intFromBool(isWhitespace(str[b - 1]));
    }
    return str[a..b];
}

pub inline fn eq(str: []const u8, comptime lit: []const u8) bool {
    if (str.len != lit.len) return false;
    const n = lit.len;
    const T = @Int(.unsigned, 8 * n);
    return switch (n) {
        0 => @compileError("Zero-length literal"),
        2, 3, 6 => @as(T, @bitCast(str[0..n].*)) == @as(T, @bitCast(lit[0..n].*)),
        7 => blk: for (str, lit) |a, b| {
            if (a != b) break :blk false;
        } else break :blk true,
        else => @compileError("Specialization unimplemented"),
    };
}

// == "atou" function specialization silliness ================================

fn Ret(comptime T: type) type {
    return struct { T, usize };
}

pub fn atou(comptime T: type, buf: []const u8) T {
    var r: T = 0;
    for (buf) |ch| r = r * 10 + (ch & 0x0f);
    return r;
}

pub fn atouForwardUntil(comptime T: type, buf: []const u8, i: usize, char: u8) Ret(T) {
    var j = i;
    var r: T = 0;
    while (buf[j] != char) : (j += 1) {
        r = r * 10 + (buf[j] & 0x0f);
    }
    return .{ r, j };
}

pub fn atouForwardUntilOrEOF(comptime T: type, buf: []const u8, i: usize, char: u8) Ret(T) {
    var j = i;
    var r: T = 0;
    while (j < buf.len and buf[j] != char) : (j += 1) {
        r = r * 10 + (buf[j] & 0x0f);
    }
    return .{ r, j };
}

pub fn atouBackwardUntil(comptime T: type, buf: []const u8, i: usize, char: u8) Ret(T) {
    var j = i;
    var mul: T = 1;
    var r: T = 0;
    while (buf[j] != char) : (j -= 1) {
        r += (buf[j] & 0x0f) * mul;
        mul *= 10;
    }
    return .{ r, j };
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
// `mem.findScalarPos` in a loop on random input and has
// a nice 20%/20% frontend/backend ratio in that scenario.
pub fn IndexIterator(comptime T: type, findme: T) type {
    return struct {
        buf: []const T,
        i: usize,
        bits: @Int(.unsigned, BlockSize),

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
