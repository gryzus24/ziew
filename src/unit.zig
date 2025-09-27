const std = @import("std");
const utl = @import("util.zig");
const fmt = std.fmt;
const io = std.io;

// == private =================================================================

inline fn KB_UNIT(kb: F5608) NumUnit {
    const KB8 = 8192 << F5608.FRAC_SHIFT;
    const MB8 = 8192 * 1024 << F5608.FRAC_SHIFT;
    const GB8 = 8192 * 1024 * 1024 << F5608.FRAC_SHIFT;

    const i =
        @as(usize, @intFromBool(kb.u >= KB8)) +
        @as(usize, @intFromBool(kb.u >= MB8)) +
        @as(usize, @intFromBool(kb.u >= GB8));

    return .{
        .n = .{ .u = kb.u >> ([4]u6{ 0, 10, 20, 30 })[i] },
        .u = ([4]NumUnit.Unit{ .kilo, .mega, .giga, .tera })[i],
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

    pub const FRAC_SHIFT = 8;
    pub const FRAC_MASK: u64 = (1 << FRAC_SHIFT) - 1;

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

    fn autoRoundPadPrecision(self: @This(), width: u8) struct { F5608, u8, u8, u8 } {
        const nr_digits = utl.nrDigits(self.n.whole());
        const digit_space = width - 1;

        // Do we have space for the fractional part?
        if (digit_space > nr_digits) {
            const p = digit_space - nr_digits;
            const rp = self.n.round(p);
            const rp_nr_digits = utl.nrDigits(rp.whole());

            if (nr_digits == rp_nr_digits) {
                @branchHint(.likely);
                return .{ rp, p -| PRECISION_DIGITS_MAX, p, rp_nr_digits };
            }
            // Got rounded up - take one digit off the fractional part and make
            // sure there is one space of padding inserted if precision digits
            // hit zero. Otherwise, there is no need to worry about inserting
            // padding here as enough `digit_space` results in `round` returning
            // itself making the `nr_digits == rp_nr_digits` check always true.
            return .{ self.n.round(p - 1), @intFromBool(p == 1), p - 1, rp_nr_digits };
        }

        // I guess we do not, let's round and not forget about the one cell
        // of padding filling the preemptively allocated space for a '.' in
        // the fractional part.
        const r0 = self.n.round(0);
        const r0_nr_digits = utl.nrDigits(r0.whole());
        const pad = @intFromBool(r0_nr_digits == digit_space);
        return .{ r0, pad, 0, r0_nr_digits };
    }

    pub fn write(
        self: @This(),
        writer: *io.Writer,
        opts: WriteOptions,
        quiet: bool,
    ) void {
        // Fits in 128 bits; width(9) + dot(1) + frac(3) + unit(1),
        // we can use overlapping stores with an XMM register for copying.
        const HALF = 16;

        const avail = writer.unusedCapacityLen();
        if (avail < HALF) {
            @branchHint(.unlikely);
            const buffer = writer.buffer;
            var pos = writer.end;
            for (0..@min(avail, 2)) |_| {
                buffer[pos] = '@';
                pos += 1;
            }
            writer.end = pos;
            return;
        }

        const alignment = opts.alignment;
        var width = opts.width;
        var precision = opts.precision;

        if (self.u == .si_one) {
            width += 1;
            precision = 0;
        }

        var rp: F5608 = undefined;
        var pad: u8 = undefined;
        var nr_digits: u8 = undefined;
        if (precision == PRECISION_VALUE_AUTO) {
            rp, pad, precision, nr_digits = self.autoRoundPadPrecision(width);
        } else {
            rp = self.n.round(precision);
            nr_digits = utl.nrDigits(rp.whole());
            pad = width -| nr_digits;
        }

        var buf: [HALF * 2]u8 = @splat(' ');
        var i = buf.len / 2;

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
                const b, const a = utl.digits2_lut(n);
                i -= 3;
                buf[i..][0..3].* = .{ '.', b, a };
            },
            else => {
                const n = (rp.frac() * 1000) / (1 << F5608.FRAC_SHIFT);
                const b, const a = utl.digits2_lut(n % 100);
                i -= 4;
                buf[i..][0..4].* = .{ '.', '0' | @as(u8, @intCast(n / 100)), b, a };
            },
            PRECISION_VALUE_AUTO => unreachable,
        }

        const n = rp.whole();
        switch (nr_digits) {
            0 => unreachable,
            1 => {
                i -= 1;
                buf[i] = '0' | @as(u8, @intCast(n));
            },
            2 => {
                i -= 2;
                buf[i..][0..2].* = utl.digits2_lut(n);
            },
            3 => {
                const b, const a = utl.digits2_lut(n % 100);
                i -= 3;
                buf[i..][0..3].* = .{ '0' | @as(u8, @intCast(n / 100)), b, a };
            },
            4 => {
                const b, const a = utl.digits2_lut(n % 100);
                const d, const c = utl.digits2_lut(n / 100);
                i -= 4;
                buf[i..][0..4].* = .{ d, c, b, a };
            },
            else => {
                @branchHint(.unlikely);
                utl.unsafeU64toa(&buf, n);
            },
        }

        if (alignment == .right)
            i -= pad;

        var w: @Vector(HALF, u8) = undefined;
        if (quiet and rp.u == 0) {
            // Copying from the second half of the buffer (instead of
            // using @splat) tricks the compiler into emitting cmovs.
            w = buf[HALF..].*;
        } else {
            w = buf[i..][0..HALF].*;
        }
        writer.buffer[writer.end..][0..HALF].* = w;
        writer.end += HALF - i;
    }
};

pub fn SizeKb(value: u64) NumUnit {
    return KB_UNIT(F5608.init(value));
}

pub fn SizeBytes(value: u64) NumUnit {
    return KB_UNIT(F5608.init(value).div(1024));
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
