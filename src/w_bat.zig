const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const math = std.math;
const mem = std.mem;

const ColorHandler = struct {
    pfullnow: utl.NumUnit,
    pfulldesign: utl.NumUnit,
    status: []const u8,

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return switch (@as(typ.BatOpt, @enumFromInt(mc.opt))) {
            .@"%fullnow" => color.firstColorAboveThreshold(
                self.pfullnow.val.roundAndTruncate(),
                mc.colors,
            ),
            .@"%fulldesign" => color.firstColorAboveThreshold(
                self.pfulldesign.val.roundAndTruncate(),
                mc.colors,
            ),
            .state => blk: {
                // make sure the first character is uppercase
                const statusid: u8 = switch (self.status[0] & (0xff - 0x20)) {
                    'D' => 0, // Discharging
                    'C' => 1, // Charging
                    'F' => 2, // Full
                    'N' => 3, // Not-charging
                    else => 4,
                };
                break :blk color.firstColorEqualThreshold(statusid, mc.colors);
            },
            .@"-" => unreachable,
        };
    }
};

pub fn widget(
    stream: anytype,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    var buf: [1024]u8 = undefined;

    const battery = wf.parts[0];
    const uevent_path = blk: {
        const ret = fmt.bufPrint(
            &buf,
            "/sys/class/power_supply/{s}/uevent\x00",
            .{battery},
        ) catch {
            utl.fatal(&.{"BAT: battery name too long"});
        };
        break :blk ret[0 .. ret.len - 1 :0];
    };

    const file = fs.cwd().openFileZ(uevent_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            utl.writeBlockStart(stream, fg.getDefault(), bg.getDefault());
            const s = fmt.bufPrint(
                &buf,
                "{s}: <not found>",
                .{battery},
            ) catch unreachable;
            utl.writeStr(stream, s);
            return utl.writeBlockEnd_GetWritten(stream);
        },
        else => utl.fatal(&.{ "BAT: check: ", @errorName(err) }),
    };
    defer file.close();

    const nread = file.read(&buf) catch |err| utl.fatal(&.{ "BAT: read: ", @errorName(err) });
    if (nread == 0) utl.fatal(&.{"BAT: empty uevent"});

    var status: []const u8 = "Unknown";
    var full_design: u64 = 0;
    var full: u64 = 0;
    var now: u64 = 0;

    var fields = mem.tokenizeScalar(u8, buf[0..nread], '\n');
    while (fields.next()) |field| {
        const eq_i = mem.lastIndexOfScalar(u8, field, '=').?;

        const key = field["POWER_SUPPLY_".len..eq_i];
        const value = field[eq_i + 1 ..];
        if (mem.eql(u8, key, "STATUS")) {
            status = value;
        } else if (mem.eql(u8, key, "CHARGE_FULL_DESIGN") or mem.eql(u8, key, "ENERGY_FULL_DESIGN")) {
            full_design = fmt.parseUnsigned(u64, value, 10) catch blk: {
                utl.warn(&.{"BAT: bad 'full_design' value"});
                break :blk 0;
            };
        } else if (mem.eql(u8, key, "CHARGE_FULL") or mem.eql(u8, key, "ENERGY_FULL")) {
            full = fmt.parseUnsigned(u64, value, 10) catch blk: {
                utl.warn(&.{"BAT: bad 'full' value"});
                break :blk 0;
            };
        } else if (mem.eql(u8, key, "CHARGE_NOW") or mem.eql(u8, key, "ENERGY_NOW")) {
            now = fmt.parseUnsigned(u64, value, 10) catch blk: {
                utl.warn(&.{"BAT: bad 'now' value"});
                break :blk 0;
            };
        }
    }

    const pfullnow = utl.Percent(now, full);
    const pfulldesign = utl.Percent(now, full_design);

    const writer = stream.writer();
    const ch = ColorHandler{
        .pfullnow = pfullnow,
        .pfulldesign = pfulldesign,
        .status = status,
    };

    utl.writeBlockStart(writer, fg.getColor(ch), bg.getColor(ch));
    utl.writeStr(writer, wf.parts[1]);
    for (wf.iterOpts()[1..], wf.iterParts()[2..]) |*opt, *part| {
        switch (@as(typ.BatOpt, @enumFromInt(opt.opt))) {
            .@"%fullnow" => pfullnow.write(writer, opt.alignment, opt.precision),
            .@"%fulldesign" => pfulldesign.write(writer, opt.alignment, opt.precision),
            .state => utl.writeStr(writer, status),
            .@"-" => unreachable,
        }
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
