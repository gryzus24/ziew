const std = @import("std");
const utl = @import("util.zig");
const fmt = std.fmt;
const io = std.io;

// == private =================================================================

fn digits2_lut(n: u64) [2]u8 {
    return "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"[n * 2 ..][0..2].*;
}

fn KB_UNIT(kb: u64, kb_f5608: F5608) NumUnit {
    const KB8 = 8192;
    const MB8 = 8192 * 1024;
    const GB8 = 8192 * 1024 * 1024;

    return switch (kb) {
        0...KB8 - 1 => .{
            .n = kb_f5608,
            .u = .kilo,
        },
        KB8...MB8 - 1 => .{
            .n = kb_f5608.div(1024),
            .u = .mega,
        },
        MB8...GB8 - 1 => .{
            .n = kb_f5608.div(1024 * 1024),
            .u = .giga,
        },
        else => .{
            .n = kb_f5608.div(1024 * 1024 * 1024),
            .u = .tera,
        },
    };
}

// == public ==================================================================

pub const PRECISION_VALUE_AUTO: comptime_int = ~@as(u8, 0);
pub const PRECISION_DIGITS_MAX: comptime_int = F5608.ROUND_STEPS.len;

pub const F5608 = struct {
    u: u64,

    pub fn init(n: u64) F5608 {
        return .{ .u = n << FRAC_SHIFT };
    }

    pub fn whole(self: @This()) u64 {
        return self.u >> FRAC_SHIFT;
    }

    pub fn frac(self: @This()) u64 {
        return self.u & FRAC_MASK;
    }

    pub fn add(self: @This(), n: u64) F5608 {
        return .{ .u = self.u + (n << FRAC_SHIFT) };
    }

    pub fn mul(self: @This(), n: u64) F5608 {
        return .{ .u = self.u * n };
    }

    pub fn div(self: @This(), n: u64) F5608 {
        return .{ .u = self.u / n };
    }

    pub fn round(self: @This(), precision: u8) F5608 {
        if (precision < ROUND_STEPS.len) {
            const step = ROUND_STEPS[precision];
            return .{ .u = (self.u + step - 1) / step * step };
        }
        return self;
    }

    pub fn roundAndTruncate(self: @This()) u64 {
        return self.round(0).whole();
    }

    const FRAC_SHIFT = 8;
    const FRAC_MASK: u64 = (1 << FRAC_SHIFT) - 1;

    const ROUND_STEPS: [3]u64 = .{
        ((1 << FRAC_SHIFT) + 1) / 2,
        ((1 << FRAC_SHIFT) + 19) / 20,
        ((1 << FRAC_SHIFT) + 199) / 200,
    };
    comptime {
        for (ROUND_STEPS) |e| {
            if (e <= 1)
                @compileError("ROUNDING_STEP too low to make an adjustment");
        }
    }
};

pub const NumUnit = struct {
    n: F5608,
    u: Unit,

    pub const Unit = enum(u8) {
        percent = '%',
        kilo = 'K',
        mega = 'M',
        giga = 'G',
        tera = 'T',
        si_one = '\x00',
        si_kilo = 'k',
        si_mega = 'm',
        si_giga = 'g',
        si_tera = 't',
    };

    pub const Alignment = enum { none, right, left };

    pub const WriteOptions = struct {
        alignment: Alignment,
        width: u8,
        precision: u8,

        pub fn setWidth(self: *@This(), w: u8) void {
            if (w == 0) {
                self.width = 1;
            } else {
                self.width = @min(w, 9);
            }
        }

        pub fn setPrecision(self: *@This(), p: u8) void {
            if (p == PRECISION_VALUE_AUTO) {
                self.precision = PRECISION_VALUE_AUTO;
            } else {
                self.precision = @min(p, PRECISION_DIGITS_MAX);
            }
        }

        pub const default: WriteOptions = .{
            .alignment = .none,
            .width = 4,
            .precision = PRECISION_VALUE_AUTO,
        };
    };

    fn autoRoundPadPrecision(self: @This(), width: u8) struct { F5608, u8, u8 } {
        const nr_digits = utl.nrDigits(self.n.whole());
        const digit_space = width - 1;

        // Do we have space for the fractional part?
        if (digit_space > nr_digits) {
            const p = digit_space - nr_digits;
            const rp = self.n.round(p);
            const rp_nr_digits = utl.nrDigits(rp.whole());

            if (nr_digits == rp_nr_digits) {
                @branchHint(.likely);
                return .{ rp, p -| PRECISION_DIGITS_MAX, p };
            }
            // Got rounded up - take one digit off the fractional part and make
            // sure there is one space of padding inserted if precision digits
            // hit zero. Otherwise, there is no need to worry about inserting
            // padding here as enough `digit_space` results in `round` returning
            // itself making the `nr_digits == rp_nr_digits` check always true.
            return .{ self.n.round(p - 1), @intFromBool(p == 1), p - 1 };
        }

        // I guess we do not, let's round and not forget about the one cell
        // of padding filling the preemptively allocated space for a '.' in
        // the fractional part.
        const r0 = self.n.round(0);
        const r0_nr_digits = utl.nrDigits(r0.whole());
        const pad = @intFromBool(r0_nr_digits == digit_space);
        return .{ r0, pad, 0 };
    }

    pub fn write(
        self: @This(),
        writer: *io.Writer,
        opts: WriteOptions,
        quiet: bool,
    ) void {
        const alignment = opts.alignment;
        var width = opts.width;
        var precision = opts.precision;

        if (self.u == .si_one) {
            width += 1;
            precision = 0;
        }

        var rp: F5608 = undefined;
        var pad: u8 = undefined;
        if (precision == PRECISION_VALUE_AUTO) {
            rp, pad, precision = self.autoRoundPadPrecision(width);
        } else {
            rp = self.n.round(precision);
            pad = width -| utl.nrDigits(rp.whole());
        }

        // should be enough
        var buf: [32]u8 = .{' '} ** 32;
        var i = buf.len;

        if (alignment == .left)
            i -= pad;

        if (self.u != .si_one) {
            i -= 1;
            buf[i] = @intFromEnum(self.u);
        }

        switch (precision) {
            0 => {},
            1 => {
                const n = (rp.frac() * 10) / (1 << F5608.FRAC_SHIFT);
                i -= 2;
                buf[i..][0..2].* = .{ '.', '0' | @as(u8, @intCast(n)) };
            },
            2 => {
                const n = (rp.frac() * 100) / (1 << F5608.FRAC_SHIFT);
                const a, const b = digits2_lut(n);
                i -= 3;
                buf[i..][0..3].* = .{ '.', a, b };
            },
            else => {
                const n = (rp.frac() * 1000) / (1 << F5608.FRAC_SHIFT);
                const a, const b = digits2_lut(n % 100);
                i -= 4;
                buf[i..][0..4].* = .{ '.', '0' | @as(u8, @intCast(n / 100)), a, b };
            },
            PRECISION_VALUE_AUTO => unreachable,
        }

        var n = rp.whole();
        while (n >= 100) : (n /= 100) {
            i -= 2;
            const decunits: u8 = @intCast(n % 100);
            buf[i..][0..2].* = digits2_lut(decunits);
        }
        if (n < 10) {
            i -= 1;
            buf[i] = '0' | @as(u8, @intCast(n));
        } else {
            // n < 100
            i -= 2;
            const decunits: u8 = @intCast(n);
            buf[i..][0..2].* = digits2_lut(decunits);
        }

        if (alignment == .right)
            i -= pad;

        if (quiet and rp.u == 0) {
            const spaces: [32]u8 = .{' '} ** 32;
            utl.writeStr(writer, spaces[i..]);
        } else {
            utl.writeStr(writer, buf[i..]);
        }
    }
};

pub fn SizeKb(value: u64) NumUnit {
    return KB_UNIT(value, F5608.init(value));
}

pub fn SizeBytes(value: u64) NumUnit {
    const kb = F5608.init(value).div(1024);
    return KB_UNIT(kb.whole(), kb);
}

pub fn Percent(value: u64, total: u64) NumUnit {
    return .{ .n = F5608.init(value * 100).div(total), .u = .percent };
}

pub fn UnitSI(value: u64) NumUnit {
    const K = 1000;
    const M = 1000 * 1000;
    const G = 1000 * 1000 * 1000;
    const T = 1000 * 1000 * 1000 * 1000;

    return switch (value) {
        0...K - 1 => .{ .n = F5608.init(value), .u = .si_one },
        K...M - 1 => .{ .n = F5608.init(value).div(K), .u = .si_kilo },
        M...G - 1 => .{ .n = F5608.init(value).div(M), .u = .si_mega },
        G...T - 1 => .{ .n = F5608.init(value).div(G), .u = .si_giga },
        else => .{ .n = F5608.init(value).div(T), .u = .si_tera },
    };
}
