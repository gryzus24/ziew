const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;

const BatSetBits = packed struct(u32) {
    state: bool = false,
    full_design: bool = false,
    full: bool = false,
    now: bool = false,
    _last_bit: bool = false,
    _pad: u27 = 0,

    fn hasSetAll(self: @This()) bool {
        const bits: u32 = @bitCast(self);
        return @as(BatSetBits, @bitCast(bits + 1))._last_bit;
    }
};

const Bat = struct {
    state: []const u8 = "Unknown",
    full_design: u64 = 0,
    full: u64 = 0,
    now: u64 = 0,
    set: BatSetBits = .{},

    fn setState(self: *@This(), state: []const u8) void {
        self.state = state;
        self.set.state = true;
    }

    fn setFullDesign(self: *@This(), full_design: u64) void {
        self.full_design = full_design;
        self.set.full_design = true;
    }

    fn setFull(self: *@This(), full: u64) void {
        self.full = full;
        self.set.full = true;
    }

    fn setNow(self: *@This(), now: u64) void {
        self.now = now;
        self.set.now = true;
    }

    pub fn checkPairs(self: @This(), ac: color.Active, base: [*]const u8) color.Hex {
        const batopt_cs: typ.BatOpt.ColorSupported = @enumFromInt(ac.opt);
        if (batopt_cs == .state) {
            return color.firstColorEQThreshold(
                switch (self.state[0] & (0xff - 0x20)) {
                    'D' => 0, // Discharging
                    'C' => 1, // Charging
                    'F' => 2, // Full
                    'N' => 3, // Not-charging
                    else => 4, // Unknown
                },
                ac.pairs.get(base),
            );
        } else {
            return color.firstColorGEThreshold(
                switch (batopt_cs) {
                    .@"%fullnow" => unt.Percent(self.now, self.full),
                    .@"%fulldesign" => unt.Percent(self.now, self.full_design),
                    .state => unreachable,
                }.n.roundU24AndTruncate(),
                ac.pairs.get(base),
            );
        }
    }
};

// == public ==================================================================

pub noinline fn widget(writer: *io.Writer, w: *const typ.Widget, base: [*]const u8) void {
    const wd = w.wid.BAT;

    const file = fs.cwd().openFileZ(wd.getPath(), .{}) catch |e| switch (e) {
        error.FileNotFound => {
            const noop: typ.Widget.NoopIndirect = .{};
            const fg, const bg = w.check(noop, base);
            utl.writeWidgetBeg(writer, fg, bg);
            utl.writeStr(writer, wd.getPsName());
            utl.writeStr(writer, ": <not found>");
            return;
        },
        else => log.fatal(&.{ "BAT: check: ", @errorName(e) }),
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const nr_read = file.read(&buf) catch |e| {
        log.fatal(&.{ "BAT: read: ", @errorName(e) });
    };
    if (nr_read == 0) log.fatal(&.{"BAT: empty uevent"});

    var bat: Bat = .{};

    var nls: utl.IndexIterator(u8, '\n') = .init(buf[0..nr_read]);
    var last: usize = 0;
    while (nls.next()) |nl| {
        const line = buf[last..nl];
        last = nl + 1;

        const i = mem.indexOfScalarPos(u8, line, 0, '=') orelse {
            log.fatal(&.{"BAT: crazy uevent"});
        };
        const key = line[0..i];
        const val = line[i + 1 ..];

        if (!mem.startsWith(u8, key, "POWER_SUPPLY_")) continue;
        const cmp = key["POWER_SUPPLY_".len..];

        if (mem.eql(u8, cmp, "STATUS")) {
            bat.setState(val);
        } else if (mem.eql(u8, cmp, "ENERGY_FULL_DESIGN") or mem.eql(u8, cmp, "CHARGE_FULL_DESIGN")) {
            bat.setFullDesign(utl.unsafeAtou64(val));
        } else if (mem.eql(u8, cmp, "ENERGY_FULL") or mem.eql(u8, cmp, "CHARGE_FULL")) {
            bat.setFull(utl.unsafeAtou64(val));
        } else if (mem.eql(u8, cmp, "ENERGY_NOW") or mem.eql(u8, cmp, "CHARGE_NOW")) {
            bat.setNow(utl.unsafeAtou64(val));
        } else {
            continue;
        }
        if (bat.set.hasSetAll()) break;
    }

    const fg, const bg = w.check(bat, base);
    utl.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const batopt: typ.BatOpt = @enumFromInt(part.opt);
        if (batopt == .arg) {
            utl.writeStr(writer, wd.getPsName());
            continue;
        }
        if (batopt == .state) {
            utl.writeStr(writer, bat.state);
            continue;
        }
        const nu = switch (batopt) {
            // zig fmt: off
            .arg            => unreachable,
            .@"%fullnow"    => unt.Percent(bat.now, bat.full),
            .@"%fulldesign" => unt.Percent(bat.now, bat.full_design),
            .state          => unreachable,
            // zig fmt: on
        };
        nu.write(writer, part.wopts, part.quiet);
    }
    wd.format.last_str.writeBytes(writer, base);
}
