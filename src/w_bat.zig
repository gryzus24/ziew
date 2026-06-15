const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const uio = @import("util/io.zig");
const ustr = @import("util/str.zig");

const Parser = struct {
    key: Key,
    value: usize,
    state: usize,

    const Key = enum(u8) {
        status,
        full_design,
        full,
        now,
    };

    const SZ = 16;
    const V = @Vector(SZ, u8);

    // zig fmt: off
    const s_status      = "STATUS";
    const s_full_design = "FULL_DESIGN";
    const s_full        = "FULL";
    const s_charge_now  = "CHARGE_NOW";
    const s_energy_now  = "ENERGY_NOW";

    const status:      V = (@as([SZ - s_status.len]u8,      @splat(0)) ++ s_status).*;
    const full_design: V = (@as([SZ - s_full_design.len]u8, @splat(0)) ++ s_full_design).*;
    const full:        V = (@as([SZ - s_full.len]u8,        @splat(0)) ++ s_full).*;
    const charge_now:  V = (@as([SZ - s_charge_now.len]u8,  @splat(0)) ++ s_charge_now).*;
    const energy_now:  V = (@as([SZ - s_energy_now.len]u8,  @splat(0)) ++ s_energy_now).*;

    const checks: [5]struct {V, usize, Key} = .{
        .{status,      (SZ - s_status.len),      Key.status},
        .{full_design, (SZ - s_full_design.len), Key.full_design},
        .{full,        (SZ - s_full.len),        Key.full},
        .{charge_now,  (SZ - s_charge_now.len),  Key.now},
        .{energy_now,  (SZ - s_energy_now.len),  Key.now},
    };
    // zig fmt: on
};

const Battery = struct {
    fields: [4]u64,

    // zig fmt: off
    const state       = @intFromEnum(Parser.Key.status);
    const full_design = @intFromEnum(Parser.Key.full_design);
    const full_now    = @intFromEnum(Parser.Key.full);
    const now         = @intFromEnum(Parser.Key.now);

    comptime {
        std.debug.assert(state       == @intFromEnum(typ.Opts.Bat.state));
        std.debug.assert(full_design == @intFromEnum(typ.Opts.Bat.fulldesign));
        std.debug.assert(full_now    == @intFromEnum(typ.Opts.Bat.fullnow));
        // N/A

        std.debug.assert(state       == 0);
        std.debug.assert(full_design == 1);
        std.debug.assert(full_now    == 2);
        std.debug.assert(now         == 3);
    }

    const State = enum(u8) {
        discharging,
        charging,
        full,
        notcharging,
        unknown,

        const WIDTH = 12;

        const names: [5][WIDTH]u8 = blk: {
            var t: [5][WIDTH]u8 = undefined;
            t[@intFromEnum(Battery.State.discharging)] = "Discharging ".*;
            t[@intFromEnum(Battery.State.charging)]    = "Charging    ".*;
            t[@intFromEnum(Battery.State.full)]        = "Full        ".*;
            t[@intFromEnum(Battery.State.notcharging)] = "Not-charging".*;
            t[@intFromEnum(Battery.State.unknown)]     = "Unknown     ".*;
            break :blk t;
        };
    };
    // zig fmt: on

    const default: Battery = .{
        .fields = @splat(0),
    };

    pub fn checkPairs(
        self: *const @This(),
        opt: u8,
        pct: bool,
        pairs: []const color.Active.Pair,
    ) color.Hex {
        _ = pct;
        const opt_color: typ.Opts.Bat.ColorSupported = @enumFromInt(opt);

        return switch (opt_color) {
            .state => color.firstColorEQThreshold(
                @intCast(self.fields[Battery.state]),
                pairs,
            ),
            .fulldesign, .fullnow => color.firstColorGEThreshold(
                unt.Percent(
                    self.fields[Battery.now],
                    self.fields[opt],
                ).n.roundU24AndTruncate(),
                pairs,
            ),
        };
    }
};

fn openAndRead(path: [*:0]const u8, buf: []u8) ![]const u8 {
    const fd = try uio.open0(path);
    defer uio.close(fd);
    const n = try uio.pread(fd, buf, 0);
    if (n == 0) return error.EmptyUevent;
    return buf[0..n];
}

// An extraordinary tour de force where
// futility meets wrongheadedness...
fn parseLine(line: []const u8, state: usize) !Parser {
    const SZ = Parser.SZ;
    const V = Parser.V;

    if (state >= Parser.checks.len) return error.Break;

    var i = line.len;
    const eq = blk: while (i >= SZ) {
        i -= SZ;
        const v: V = line[i..][0..SZ].*;
        const m: u16 = @bitCast(v == @as(V, @splat('=')));
        const j = @ctz(m);
        if (j != SZ) break :blk i + j;
        if (i == 0) return error.InvalidUevent;
        if (i < SZ) i = SZ;
    } else return error.InvalidUevent;

    const prefix = "POWER_SUPPLY_XXXX";
    if (eq < prefix.len) return error.Continue;

    const current: V = line[eq - SZ .. eq][0..SZ].*;

    for (Parser.checks[state..]) |check| {
        const v, const key_len_complement, const key = check;
        const m: u16 = @bitCast(current == v);
        if (@ctz(m) == key_len_complement) {
            const vstr = line[eq + 1 ..];
            // zig fmt: off
            const state_lut: [8]u8 = .{
                @intFromEnum(Battery.State.unknown),
                @intFromEnum(Battery.State.charging),    // vstr[0] == 'C'
                @intFromEnum(Battery.State.discharging), // vstr[0] == 'D'
                @intFromEnum(Battery.State.full),        // vstr[0] == 'F'
                @intFromEnum(Battery.State.unknown),
                @intFromEnum(Battery.State.unknown),
                @intFromEnum(Battery.State.unknown),
                @intFromEnum(Battery.State.notcharging), // vstr[0] == 'N'
            };
            // zig fmt: on
            const value: usize = switch (key) {
                // Make uppercase, switch off 0x40, reduce a bit, lookup.
                .status => state_lut[(vstr[0] & (0xff - 0x20 - 0x40)) >> 1],
                .full_design, .full, .now => ustr.atou(u64, vstr),
            };
            // Technically the order of fields in uevent shouldn't change,
            // but let's be fancy and account for that possibility, change
            // state only if `starting state` == `found state`, so that it
            // doesn't form "holes" as that would require a different data
            // structure to account for them and would get too complicated
            // even for this questionable exercise of SIMD uevent parsing.
            var advance: usize = 0;
            if (state == @intFromEnum(key)) advance += 1;
            if (state == @intFromEnum(Parser.Key.now)) advance += 1;
            return .{
                .key = key,
                .value = value,
                .state = state + advance,
            };
        }
    }
    return error.Continue;
}

// == public ==================================================================

pub fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    parts: []const typ.Format.Part,
    base: [*]const u8,
) void {
    const wd = w.getDataConst(.BAT, base);

    var buf: [1024]u8 = undefined;
    const data = openAndRead(wd.getPath(), &buf) catch |e| {
        const fg, const bg = w.colorForceStatic();
        typ.writeWidgetBeg(writer, fg, bg);
        uio.writeStr(writer, wd.getPsName());
        uio.writeStr(writer, ": ");
        uio.writeStr(writer, switch (e) {
            error.FileNotFound => "<not found>",
            else => @errorName(e),
        });
        return;
    };

    var bat: Battery = .default;

    var state: usize = 0;
    var nls: ustr.IndexIterator(u8, '\n') = .init(data);
    var last: usize = 0;
    while (nls.next()) |nl| {
        const line = data[last..nl];
        last = nl + 1;

        const ret = parseLine(line, state) catch |e| switch (e) {
            error.Break => break,
            error.Continue => continue,
            error.InvalidUevent => log.fatal(&.{ "BAT: ", @errorName(e) }),
        };
        bat.fields[@intFromEnum(ret.key)] = ret.value;
        state = ret.state;
    }

    const fg, const bg = w.check(&bat, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (parts) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.Opts.Bat = @enumFromInt(part.opt);
        switch (opt) {
            .state => {
                if (Battery.State.WIDTH > writer.unusedCapacityLen()) {
                    @branchHint(.unlikely);
                    break;
                }
                writer.buffer[writer.end..][0..Battery.State.WIDTH].* =
                    Battery.State.names[bat.fields[Battery.state]];
                writer.end += Battery.State.WIDTH;
            },
            .fulldesign, .fullnow => {
                const nu = if (part.flags.pct)
                    unt.Percent(bat.fields[Battery.now], bat.fields[part.opt])
                else
                    unt.UnitSI(bat.fields[part.opt]);
                nu.write(writer, part.wopts);
            },
        }
    }
}
