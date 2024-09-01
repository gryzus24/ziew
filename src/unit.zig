const std = @import("std");
const utl = @import("util.zig");
const typ = @import("type.zig");

// == public ==================================================================

pub const PRECISION_DIGITS_MAX = F5608.ROUND_EPS.len;

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
        return if (precision < ROUND_EPS.len)
            self._roundup(ROUND_EPS[precision])
        else
            self;
    }

    pub fn roundAndTruncate(self: @This()) u64 {
        return self.round(0).whole();
    }

    pub fn write(
        self: @This(),
        with_write: anytype,
        digits_max: u8,
        alignment: typ.Alignment,
        precision: u8,
        unitchar: u8,
    ) void {
        const rounded = self.round(precision);
        const int = rounded.whole();

        if (alignment == .right)
            writeAlignment(with_write, int, digits_max);

        utl.writeInt(with_write, int);
        if (precision > 0) {
            const fpmul = FRAC_PRECISION_MULS[@min(precision, FRAC_PRECISION_MULS.len - 1)];

            utl.writeStr(with_write, &[1]u8{'.'});
            utl.writeIntOpts(
                with_write,
                (rounded.frac() * fpmul) / (1 << FRAC_SHIFT),
                .{ .width = precision, .alignment = .right, .fill = '0' },
            );
        }
        if (unitchar != '\x00')
            utl.writeStr(with_write, &[1]u8{unitchar});

        if (alignment == .left)
            writeAlignment(with_write, int, digits_max);
    }

    const FRAC_SHIFT = 8;
    const FRAC_MASK: u64 = (1 << FRAC_SHIFT) - 1;
    const FRAC_PRECISION_MULS: [4]u64 = .{ 1, 10, 100, 1000 };

    const ROUND_EPS = [_]u64{
        ((1 << FRAC_SHIFT) + 1) / 2,
        ((1 << FRAC_SHIFT) + 19) / 20,
        ((1 << FRAC_SHIFT) + 199) / 200,
    };
    comptime {
        for (ROUND_EPS) |e| {
            if (e <= 1)
                @compileError("FRAC_SHIFT too low to satisfy rounding precision");
        }
    }

    fn _roundup(self: @This(), quants: u64) F5608 {
        return .{ .u = (self.u + quants - 1) / quants * quants };
    }
};

pub const Unit = enum {
    percent,
    cpu_percent,
    kilo,
    mega,
    giga,
    tera,
    si_one,
    si_kilo,
    si_mega,
    si_giga,
    si_tera,
};

pub const NumUnit = struct {
    val: F5608,
    unit: Unit,

    pub fn write(
        self: @This(),
        with_write: anytype,
        alignment: typ.Alignment,
        precision: u8,
    ) void {
        var p = precision;
        const digits_max: u8 = switch (self.unit) {
            .percent, .si_kilo, .si_mega, .si_giga, .si_tera => 3,
            .cpu_percent, .kilo, .mega, .giga, .tera => 4,
            .si_one => blk: {
                p = 0;
                break :blk @as(u8, 4) + @intFromBool(precision != 0) + precision;
            },
        };
        self.val.write(with_write, digits_max, alignment, p, switch (self.unit) {
            .percent, .cpu_percent => '%',
            .kilo => 'K',
            .mega => 'M',
            .giga => 'G',
            .tera => 'T',
            .si_one => '\x00',
            .si_kilo => 'k',
            .si_mega => 'm',
            .si_giga => 'g',
            .si_tera => 't',
        });
    }
};

pub fn SizeKb(value: u64) NumUnit {
    const KB4 = 4096;
    const MB4 = 4096 * 1024;
    const GB4 = 4096 * 1024 * 1024;

    return switch (value) {
        0...KB4 - 1 => .{
            .val = F5608.init(value),
            .unit = .kilo,
        },
        KB4...MB4 - 1 => .{
            .val = F5608.init(value).div(1024),
            .unit = .mega,
        },
        MB4...GB4 - 1 => .{
            .val = F5608.init(value).div(1024 * 1024),
            .unit = .giga,
        },
        else => .{
            .val = F5608.init(value).div(1024 * 1024 * 1024),
            .unit = .tera,
        },
    };
}

pub fn Percent(value: u64, total: u64) NumUnit {
    return .{ .val = F5608.init(value * 100).div(total), .unit = .percent };
}

pub fn UnitSI(value: u64) NumUnit {
    const K = 1000;
    const M = 1000 * 1000;
    const G = 1000 * 1000 * 1000;
    const T = 1000 * 1000 * 1000 * 1000;

    return switch (value) {
        0...K - 1 => .{ .val = F5608.init(value), .unit = .si_one },
        K...M - 1 => .{ .val = F5608.init(value).div(K), .unit = .si_kilo },
        M...G - 1 => .{ .val = F5608.init(value).div(M), .unit = .si_mega },
        G...T - 1 => .{ .val = F5608.init(value).div(G), .unit = .si_giga },
        else => .{ .val = F5608.init(value).div(T), .unit = .si_tera },
    };
}

// == private =================================================================

fn writeAlignment(with_write: anytype, value: u64, digits_max: u8) void {
    const space_left = digits_max -| @as(u8, switch (value) {
        0...9 => 1,
        10...99 => 2,
        100...999 => 3,
        else => 4,
    });
    utl.writeStr(with_write, (" " ** 0x10)[0 .. space_left & 0x0f]);
}
