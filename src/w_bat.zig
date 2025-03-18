const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
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

    pub fn checkOptColors(self: @This(), oc: color.OptColors) ?*const [7]u8 {
        const batopt_cs: typ.BatOpt.ColorSupported = @enumFromInt(oc.opt);
        if (batopt_cs == .state) {
            return color.firstColorEQThreshold(
                switch (self.state[0] & (0xff - 0x20)) {
                    'D' => 0, // Discharging
                    'C' => 1, // Charging
                    'F' => 2, // Full
                    'N' => 3, // Not-charging
                    else => 4, // Unknown
                },
                oc.colors,
            );
        } else {
            return color.firstColorGEThreshold(
                switch (batopt_cs) {
                    .@"%fullnow" => unt.Percent(self.now, self.full),
                    .@"%fulldesign" => unt.Percent(self.now, self.full_design),
                    .state => unreachable,
                }.n.roundAndTruncate(),
                oc.colors,
            );
        }
    }
};

// == public ==================================================================

pub fn widget(stream: anytype, w: *const typ.Widget) []const u8 {
    const wd = w.wid.BAT;

    const file = fs.cwd().openFileZ(wd.path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            utl.writeBlockStart(stream, wd.fg.getDefault(), wd.bg.getDefault());
            utl.writeStr(stream, wd.ps_name);
            utl.writeStr(stream, ": <not found>");
            return utl.writeBlockEnd_GetWritten(stream);
        },
        else => utl.fatal(&.{ "BAT: check: ", @errorName(e) }),
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const nread = file.read(&buf) catch |e| {
        utl.fatal(&.{ "BAT: read: ", @errorName(e) });
    };
    if (nread == 0) utl.fatal(&.{"BAT: empty uevent"});

    var bat: Bat = .{};

    var lines = mem.tokenizeScalar(u8, buf[0..nread], '\n');
    while (lines.next()) |line| {
        const eqi = mem.indexOfScalar(u8, line, '=') orelse {
            utl.fatal(&.{"BAT: crazy uevent"});
        };
        const key = line[0..eqi];
        const val = line[eqi + 1 ..];

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

    const writer = stream.writer();

    utl.writeBlockStart(writer, wd.fg.getColor(bat), wd.bg.getColor(bat));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(writer, part.str);

        const batopt: typ.BatOpt = @enumFromInt(part.opt);
        if (batopt == .arg) {
            utl.writeStr(writer, wd.ps_name);
            continue;
        }
        if (batopt == .state) {
            utl.writeStr(writer, bat.state);
            continue;
        }
        (switch (batopt) {
            // zig fmt: off
            .arg            => unreachable,
            .@"%fullnow"    => unt.Percent(bat.now, bat.full),
            .@"%fulldesign" => unt.Percent(bat.now, bat.full_design),
            .state          => unreachable,
            // zig fmt: on
        }).write(writer, part.wopts, part.flags.quiet);
    }
    utl.writeStr(writer, wd.format.part_last);
    return utl.writeBlockEnd_GetWritten(stream);
}
