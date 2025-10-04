const std = @import("std");

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
