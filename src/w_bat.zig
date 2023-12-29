const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const fs = std.fs;
const math = std.math;

const CHARGE_FULL_REFRESH_AFTER_DEFAULT = 600;

const CHARGE_FULL_PATH = "/sys/class/power_supply/BAT1/charge_full";
const CHARGE_FULL_DESIGN_PATH = "/sys/class/power_supply/BAT1/charge_full_design";
const CHARGE_NOW_PATH = "/sys/class/power_supply/BAT1/charge_now";
const STATUS_PATH = "/sys/class/power_supply/BAT1/status";

fn readChargeFile(path: [:0]const u8) u64 {
    const file = fs.cwd().openFileZ(path, .{}) catch |err| {
        utl.fatal("BAT: {s}: open: {}", .{ path, err });
    };
    defer file.close();

    var buf: [1 + fmt.count("{}", .{math.maxInt(u64)})]u8 = undefined;
    const nread = file.read(&buf) catch |err| {
        utl.fatal("BAT: {s}: read: {}", .{ path, err });
    };
    const result = fmt.parseUnsigned(u64, buf[0 .. nread - 1], 10) catch |err| {
        utl.fatal("BAT: {s}: parse: {}", .{ path, err });
    };
    if (result == 0)
        utl.fatal("BAT: {s}: no charge", .{path});

    return result;
}

fn readStatusFile(buf: *[64]u8) []const u8 {
    const file = fs.cwd().openFileZ(STATUS_PATH, .{}) catch |err| {
        utl.fatal("BAT: status: open: {}", .{err});
    };
    defer file.close();

    const nread = file.read(buf) catch |err| {
        utl.fatal("BAT: status: read: {}", .{err});
    };

    // strip $'\n'
    return buf[0 .. nread - 1];
}

const ColorHandler = struct {
    pcapacity: utl.NumUnit,
    pcharge: utl.NumUnit,
    status: ?[]const u8,

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return switch (@as(typ.BatOpt, @enumFromInt(mc.opt))) {
            .@"%capacity" => color.firstColorAboveThreshold(self.pcapacity.val, mc.colors),
            .@"%charge" => color.firstColorAboveThreshold(self.pcharge.val, mc.colors),
            .state => blk: {
                var statusbuf: [64]u8 = undefined;

                const t = self.status orelse readStatusFile(&statusbuf);
                // make sure the first character is uppercase
                const statusid: u8 = switch (t[0] & (0xff - 0x20)) {
                    'D' => 0, // Discharging
                    'C' => 1, // Charging
                    'F' => 2, // Full
                    else => 3,
                };
                break :blk color.firstColorEqualThreshold(statusid, mc.colors);
            },
        };
    }
};

var _charge_full: u64 = 0;
var _charge_full_design: u64 = 0;
var _charge_full_refresh_after: u32 = 0;

pub fn widget(
    stream: anytype,
    cf: *const cfg.ConfigFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    if (_charge_full_refresh_after == 0) {
        _charge_full = readChargeFile(CHARGE_FULL_PATH);
        _charge_full_design = readChargeFile(CHARGE_FULL_DESIGN_PATH);
        _charge_full_refresh_after = CHARGE_FULL_REFRESH_AFTER_DEFAULT;
    } else {
        _charge_full_refresh_after -= 1;
    }

    const charge_now = readChargeFile(CHARGE_NOW_PATH);
    const pcapacity = utl.percentOf(charge_now, _charge_full);
    const pcharge = utl.percentOf(charge_now, _charge_full_design);

    var statusbuf: [64]u8 = undefined;
    var status: ?[]const u8 = null;

    for (cf.iterOpts()) |*opt| {
        if (@as(typ.BatOpt, @enumFromInt(opt.opt)) == .state) {
            status = readStatusFile(&statusbuf);
            break;
        }
    }

    const writer = stream.writer();
    const color_handler = ColorHandler{
        .pcapacity = pcapacity,
        .pcharge = pcharge,
        .status = status,
    };

    utl.writeBlockStart(
        writer,
        color.colorFromColorUnion(fg, color_handler),
        color.colorFromColorUnion(bg, color_handler),
    );
    utl.writeStr(writer, cf.parts[0]);
    for (cf.iterOpts(), cf.iterParts()[1..]) |*opt, *part| {
        switch (@as(typ.BatOpt, @enumFromInt(opt.opt))) {
            .@"%capacity" => utl.writeNumUnit(
                writer,
                pcapacity,
                opt.alignment,
                opt.precision,
            ),
            .@"%charge" => utl.writeNumUnit(
                writer,
                pcharge,
                opt.alignment,
                opt.precision,
            ),
            .state => utl.writeStr(writer, status.?),
        }
        utl.writeStr(writer, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}

pub fn hasBattery() bool {
    const file = fs.cwd().openFileZ(CHARGE_NOW_PATH, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            utl.warn("BAT: check: {}", .{err});
            return false;
        },
    };
    file.close();

    return true;
}

pub fn widget_no_battery(stream: anytype) []const u8 {
    utl.writeBlockStart(stream, null, null);
    utl.writeStr(stream, "<no battery>");
    return utl.writeBlockEnd_GetWritten(stream);
}
