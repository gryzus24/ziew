const std = @import("std");
const cfg = @import("config.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const fs = std.fs;
const mem = std.mem;

pub fn widget(
    stream: anytype,
    cf: *const cfg.ConfigFormat,
    fg: *const cfg.ColorUnion,
    bg: *const cfg.ColorUnion,
) []const u8 {
    const file = fs.cwd().openFileZ("/proc/loadavg", .{}) catch |err|
        utl.fatal("LOAD: open: {}", .{err});

    defer file.close();

    var loadavg_buf: [64]u8 = undefined;
    const nread = file.read(&loadavg_buf) catch |err|
        utl.fatal("LOAD: read: {}", .{err});

    var fields = mem.tokenizeScalar(u8, loadavg_buf[0..nread], ' ');

    const slots = blk: {
        var w: [3][]const u8 = undefined;
        w[@intFromEnum(typ.LoadOpt.@"1")] = fields.next().?;
        w[@intFromEnum(typ.LoadOpt.@"5")] = fields.next().?;
        w[@intFromEnum(typ.LoadOpt.@"15")] = fields.peek().?;
        break :blk w;
    };

    const fg_hex = switch (fg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => unreachable,
    };
    const bg_hex = switch (bg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => unreachable,
    };
    utl.writeBlockStart(stream, fg_hex, bg_hex);
    utl.writeStr(stream, cf.parts[0]);
    for (0..cf.nparts - 1) |i| {
        utl.writeStr(stream, slots[cf.opts[i]]);
        utl.writeStr(stream, cf.parts[1 + i]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
