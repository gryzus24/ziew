const std = @import("std");
const cfg = @import("config.zig");
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

fn checkManyColors(
    pcapacity: utl.NumUnit,
    pcharge: utl.NumUnit,
    status: ?[]const u8,
    mc: cfg.ManyColors,
) ?*const [7]u8 {
    switch (@as(typ.BatOpt, @enumFromInt(mc.opt))) {
        .@"%capacity" => return utl.checkColor(pcapacity.val, mc.colors),
        .@"%charge" => return utl.checkColor(pcharge.val, mc.colors),
        .state => {
            var statusbuf: [64]u8 = undefined;

            const t = status orelse readStatusFile(&statusbuf);
            const statusid: u8 = switch (t[0] & (0xff - 0x20)) {
                'D' => 0, // Discharging
                'C' => 1, // Charging
                'F' => 2, // Full
                else => 3,
            };
            for (mc.colors) |*color| if (color.thresh == statusid) {
                return &color.hex;
            };
            return null;
        },
    }
}

var _charge_full: u64 = 0;
var _charge_full_design: u64 = 0;
var _charge_full_refresh_after: u32 = 0;

pub fn widget(
    stream: anytype,
    cf: *const cfg.ConfigFormat,
    fg: *const cfg.ColorUnion,
    bg: *const cfg.ColorUnion,
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

    for (0..cf.nparts - 1) |i| {
        if (@as(typ.BatOpt, @enumFromInt(cf.opts[i])) == .state) {
            status = readStatusFile(&statusbuf);
            break;
        }
    }

    const fg_hex = switch (fg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkManyColors(pcapacity, pcharge, status, t),
    };
    const bg_hex = switch (bg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkManyColors(pcapacity, pcharge, status, t),
    };

    const writer = stream.writer();

    utl.writeBlockStart(writer, fg_hex, bg_hex);
    utl.writeStr(writer, cf.parts[0]);
    for (0..cf.nparts - 1) |i| {
        const nu = switch (@as(typ.BatOpt, @enumFromInt(cf.opts[i]))) {
            .@"%capacity" => pcapacity,
            .@"%charge" => pcharge,
            .state => {
                utl.writeStr(writer, status.?);
                utl.writeStr(writer, cf.parts[1 + i]);
                continue;
            },
        };

        const prec = cf.opts_precision[i];
        const ali = cf.opts_alignment[i];

        if (ali == .right)
            utl.writeAlignment(writer, .percent, nu.val, prec);

        if (prec == 0) {
            utl.writeInt(writer, @intFromFloat(@round(nu.val)));
        } else {
            utl.writeFloat(writer, nu.val, prec);
        }
        utl.writeStr(writer, &[1]u8{nu.unit});

        if (ali == .left)
            utl.writeAlignment(writer, .percent, nu.val, prec);

        utl.writeStr(writer, cf.parts[1 + i]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
