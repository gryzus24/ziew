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

    const status: V      = ((.{0} ** (SZ - s_status.len))      ++ s_status).*;
    const full_design: V = ((.{0} ** (SZ - s_full_design.len)) ++ s_full_design).*;
    const full: V        = ((.{0} ** (SZ - s_full.len))        ++ s_full).*;
    const charge_now: V  = ((.{0} ** (SZ - s_charge_now.len))  ++ s_charge_now).*;
    const energy_now: V  = ((.{0} ** (SZ - s_energy_now.len))  ++ s_energy_now).*;

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

    const state = @intFromEnum(Parser.Key.status);
    const full_design = @intFromEnum(Parser.Key.full_design);
    const full_now = @intFromEnum(Parser.Key.full);
    const now = @intFromEnum(Parser.Key.now);

    comptime {
        const assert = std.debug.assert;
        assert(state == @intFromEnum(typ.Options.Bat.state));
        assert(full_design == @intFromEnum(typ.Options.Bat.fulldesign));
        assert(full_now == @intFromEnum(typ.Options.Bat.fullnow));
    }

    const State = enum(u8) {
        discharging,
        charging,
        full,
        notcharging,
        unknown,

        // zig fmt: off
        const names: [5][12]u8 = blk: {
            var t: [5][12]u8 = undefined;
            t[@intFromEnum(Battery.State.discharging)] = "Discharging ".*;
            t[@intFromEnum(Battery.State.charging)]    = "Charging    ".*;
            t[@intFromEnum(Battery.State.full)]        = "Full        ".*;
            t[@intFromEnum(Battery.State.notcharging)] = "Not-charging".*;
            t[@intFromEnum(Battery.State.unknown)]     = "Unknown     ".*;
            break :blk t;
        };
        // zig fmt: on
    };

    const default: Battery = .{
        .fields = @splat(0),
    };

    pub fn checkPairs(self: *const @This(), ac: color.Active, base: [*]const u8) color.Hex {
        return switch (@as(typ.Options.Bat.ColorAdjacent, @enumFromInt(ac.opt))) {
            .state => color.firstColorEQThreshold(
                @intCast(self.fields[Battery.state]),
                ac.pairs.get(base),
            ),
            .fulldesign, .fullnow => color.firstColorGEThreshold(
                unt.Percent(
                    self.fields[Battery.now],
                    self.fields[ac.opt],
                ).n.roundU24AndTruncate(),
                ac.pairs.get(base),
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

pub inline fn widget(writer: *uio.Writer, w: *const typ.Widget, base: [*]const u8) void {
    const wd = w.data.BAT;

    var buf: [1024]u8 = undefined;
    const data = openAndRead(wd.getPath(), &buf) catch |e| {
        const handler: typ.Widget.NoopColorHandler = .{};
        const fg, const bg = w.check(handler, base);
        return typ.writeWidget(
            writer,
            fg,
            bg,
            &[3][]const u8{
                wd.getPsName(), ": ", switch (e) {
                    error.FileNotFound => "<not found>",
                    else => @errorName(e),
                },
            },
        );
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
    for (w.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.Options.Bat = @enumFromInt(part.opt);
        switch (opt) {
            .state, .arg => {
                const SZ = 12;
                const expected = @max(SZ, typ.Widget.Data.Bat.PS_NAME_SIZE_MAX);
                comptime std.debug.assert(expected == SZ);

                if (expected > writer.unusedCapacityLen()) {
                    @branchHint(.unlikely);
                    break;
                }
                writer.buffer[writer.end..][0..SZ].* =
                    if (opt == .state)
                        Battery.State.names[bat.fields[Battery.state]]
                    else
                        // It would seem it is accessing invalid memory, but it
                        // doesn't even go past the NUL byte of the widget path
                        // in the common case of `wd.ps_len == 4`.
                        wd.path[wd.ps_off..].ptr[0..SZ].*;
                writer.end += SZ;
            },
            .fulldesign, .fullnow => {
                const flags: unt.NumUnit.Flags = .{
                    .quiet = part.flags.quiet,
                    .negative = false,
                };
                var nu: unt.NumUnit = undefined;
                if (part.flags.pct) {
                    nu = unt.Percent(bat.fields[Battery.now], bat.fields[part.opt]);
                } else {
                    nu = unt.UnitSI(bat.fields[part.opt]);
                }
                nu.write(writer, part.wopts, flags);
            },
        }
    }
}
