const std = @import("std");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;

// == public ==================================================================

pub const PRECISION_AUTO_VALUE: comptime_int = @as(u8, @bitCast(@as(i8, -1)));
pub const PRECISION_DIGITS_MAX: comptime_int = F5608.FRAC_ROUNDING_STEPS.len;

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
        if (precision >= FRAC_ROUNDING_STEPS.len)
            return self;

        const step = FRAC_ROUNDING_STEPS[precision];
        return .{ .u = (self.u + step - 1) / step * step };
    }

    pub fn roundAndTruncate(self: @This()) u64 {
        return self.round(0).whole();
    }

    const FRAC_SHIFT = 8;
    const FRAC_MASK: u64 = (1 << FRAC_SHIFT) - 1;

    const FRAC_ROUNDING_STEPS: [3]u64 = .{
        ((1 << FRAC_SHIFT) + 1) / 2,
        ((1 << FRAC_SHIFT) + 19) / 20,
        ((1 << FRAC_SHIFT) + 199) / 200,
    };
    comptime {
        for (FRAC_ROUNDING_STEPS) |e| {
            if (e <= 1)
                @compileError("FRAC_SHIFT too low to satisfy rounding precision");
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
        alignment: Alignment = .none,
        width: u8 = 3,
        precision: u8 = PRECISION_AUTO_VALUE,
    };

    fn roundedPadPrecisionAuto(self: @This(), width: u8) struct { F5608, u8, u8 } {
        const rounded0 = self.n.round(0);
        const rounded0_nr_digits = utl.nrDigits(rounded0.whole());

        if (rounded0_nr_digits >= width)
            return .{ rounded0, 0, 0 };

        const nr_digits = utl.nrDigits(self.n.whole());
        const frac_digits_space = width - nr_digits - 1;

        // Can't do much - only the decimal point fits.
        if (frac_digits_space == 0)
            return .{ rounded0, 1, 0 };

        if (frac_digits_space >= PRECISION_DIGITS_MAX)
            return .{
                self.n,
                frac_digits_space - PRECISION_DIGITS_MAX,
                PRECISION_DIGITS_MAX,
            };

        const r = self.n.round(frac_digits_space);
        if (utl.nrDigits(r.whole()) == nr_digits)
            return .{ r, 0, frac_digits_space };

        // Got rounded up - take one digit off the fractional part and make sure
        // there is one space of padding inserted if `frac_digits_space` hits 0.
        return .{
            self.n.round(frac_digits_space - 1),
            @intFromBool(frac_digits_space == 1),
            frac_digits_space - 1,
        };
    }

    pub fn write(
        self: @This(),
        with_write: anytype,
        opts: WriteOptions,
    ) void {
        const alignment = opts.alignment;
        var width = opts.width;
        var precision = opts.precision;

        if (self.u == .si_one) {
            width += 1;
            precision = 0;
        }
        width &= 0x0f; // space for the integer part of a number

        var rounded: F5608 = undefined;
        var pad: u8 = undefined;
        if (precision == PRECISION_AUTO_VALUE) {
            rounded, pad, precision = self.roundedPadPrecisionAuto(width);
        } else {
            rounded = self.n.round(precision);
            pad = width -| utl.nrDigits(rounded.whole());
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
                const n = (rounded.frac() * 10) / (1 << F5608.FRAC_SHIFT);
                i -= 2;
                buf[i..][0..2].* = .{ '.', '0' | @as(u8, @intCast(n)) };
            },
            2 => {
                const n = (rounded.frac() * 100) / (1 << F5608.FRAC_SHIFT);
                i -= 3;
                buf[i..][0..3].* = .{
                    '.',
                    '0' | @as(u8, @intCast(n / 10 % 10)),
                    '0' | @as(u8, @intCast(n % 10)),
                };
            },
            3 => {
                const n = (rounded.frac() * 1000) / (1 << F5608.FRAC_SHIFT);
                i -= 4;
                buf[i..][0..4].* = .{
                    '.',
                    '0' | @as(u8, @intCast(n / 100 % 10)),
                    '0' | @as(u8, @intCast(n / 10 % 10)),
                    '0' | @as(u8, @intCast(n % 10)),
                };
            },
            else => {
                if (PRECISION_DIGITS_MAX > 3)
                    @compileError("well...");

                unreachable;
            },
        }

        var n = rounded.whole();
        while (n >= 100) : (n /= 100) {
            i -= 2;
            buf[i..][0..2].* = fmt.digits2(n % 100);
        }
        if (n < 10) {
            i -= 1;
            buf[i] = '0' | @as(u8, @intCast(n));
        } else {
            i -= 2;
            buf[i..][0..2].* = fmt.digits2(n);
        }

        if (alignment == .right)
            i -= pad;

        utl.writeStr(with_write, buf[i..]);
    }
};

pub fn SizeKb(value: u64) NumUnit {
    const KB4 = 4096;
    const MB4 = 4096 * 1024;
    const GB4 = 4096 * 1024 * 1024;

    return switch (value) {
        0...KB4 - 1 => .{
            .n = F5608.init(value),
            .u = .kilo,
        },
        KB4...MB4 - 1 => .{
            .n = F5608.init(value).div(1024),
            .u = .mega,
        },
        MB4...GB4 - 1 => .{
            .n = F5608.init(value).div(1024 * 1024),
            .u = .giga,
        },
        else => .{
            .n = F5608.init(value).div(1024 * 1024 * 1024),
            .u = .tera,
        },
    };
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
