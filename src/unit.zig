const std = @import("std");
const utl = @import("util.zig");
const typ = @import("type.zig");

// == public ==================================================================

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
        return if (precision < FRAC_ROUNDING_STEPS.len)
            self._roundup(FRAC_ROUNDING_STEPS[precision])
        else
            self;
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

    fn _roundup(self: @This(), quants: u64) F5608 {
        return .{ .u = (self.u + quants - 1) / quants * quants };
    }
};

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

pub const NumUnit = struct {
    n: F5608,
    u: Unit,

    fn roundedPadPrecision(
        self: @This(),
        width: u8,
        precision: u8,
    ) struct { F5608, u8, u8 } {
        const rounded = self.n.round(precision);
        const rounded_nr_digits = utl.nrDigits(rounded.whole());

        if (self.u == .si_one or precision != 0) {
            return .{
                rounded,
                @intFromBool(self.u == .si_one) + width -| rounded_nr_digits,
                precision,
            };
        }
        if (rounded_nr_digits >= width)
            return .{ rounded, 0, precision };

        // `nr_digits` might be one less than `rounded_nr_digits`.
        const nr_digits = utl.nrDigits(self.n.whole());
        const nr_frac_digits = width - nr_digits - 1;

        // Can't do much - only the decimal point fits.
        if (nr_frac_digits == 0)
            return .{ rounded, 1, 0 };

        if (nr_frac_digits >= PRECISION_DIGITS_MAX)
            return .{
                self.n,
                nr_frac_digits - PRECISION_DIGITS_MAX,
                PRECISION_DIGITS_MAX,
            };

        const r = self.n.round(nr_frac_digits);
        if (utl.nrDigits(r.whole()) == nr_digits)
            return .{ r, 0, nr_frac_digits };

        // Got rounded up - take one digit off the fractional part and make sure
        // there is one space of padding inserted if `nr_decimal_digits` hits 0.
        return .{
            self.n.round(nr_frac_digits - 1),
            @intFromBool(nr_frac_digits == 1),
            nr_frac_digits - 1,
        };
    }

    pub fn write(
        self: @This(),
        with_write: anytype,
        alignment: typ.Alignment,
        width: u8,
        precision: u8,
    ) void {
        const rounded, const pad, const new_precision =
            self.roundedPadPrecision(width, precision);

        if (alignment == .right)
            utl.writeStr(with_write, (" " ** 0x10)[0 .. pad & 0x0f]);

        utl.writeInt(with_write, rounded.whole());
        if (new_precision != 0) {
            switch (new_precision) {
                0 => unreachable,
                1 => {
                    const n = (rounded.frac() * 10) / (1 << F5608.FRAC_SHIFT);
                    utl.writeStr(with_write, &.{
                        '.',
                        '0' | @as(u8, @intCast(n)),
                    });
                },
                2 => {
                    const n = (rounded.frac() * 100) / (1 << F5608.FRAC_SHIFT);
                    utl.writeStr(with_write, &.{
                        '.',
                        '0' | @as(u8, @intCast(n / 10 % 10)),
                        '0' | @as(u8, @intCast(n % 10)),
                    });
                },
                3 => {
                    const n = (rounded.frac() * 1000) / (1 << F5608.FRAC_SHIFT);
                    utl.writeStr(with_write, &.{
                        '.',
                        '0' | @as(u8, @intCast(n / 100 % 10)),
                        '0' | @as(u8, @intCast(n / 10 % 10)),
                        '0' | @as(u8, @intCast(n % 10)),
                    });
                },
                else => {
                    if (PRECISION_DIGITS_MAX > 3)
                        @compileError("well...");

                    unreachable;
                },
            }
        }
        if (self.u != .si_one)
            utl.writeStr(with_write, &[1]u8{@intFromEnum(self.u)});

        if (alignment == .left)
            utl.writeStr(with_write, (" " ** 0x10)[0 .. pad & 0x0f]);
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
