const std = @import("std");

const cfg = @import("src/config.zig");
const typ = @import("src/type.zig");
const uio = @import("src/util/io.zig");
const umem = @import("src/util/mem.zig");

const AT_FDCWD = std.posix.AT.FDCWD;
const O = std.os.linux.O;
const openatZ = std.posix.openatZ;

var bss: [0x3a00]u8 align(16) = undefined;

fn inBytes(comptime T: type, len: usize) usize {
    return @sizeOf(T) * len;
}

fn real_main(argc: c_int, argv: [*]const [*:0]const u8) !void {
    const args = argv[1..@intCast(argc)];
    const nr_args_expected = 5;

    if (args.len != nr_args_expected)
        return error.InvalidArgs;

    // zig fmt: off
    const config_path,
    const data_path,
    const widg_path,
    const intr_path,
    const wids_path = args[0..nr_args_expected].*;
    // zig fmt: on

    var reg: umem.Region = .init(&bss, "main");
    const filebuf, const scratch = typ.allocConfigParserMem(&reg);
    var bf: uio.BufferedFile = .init(try uio.open0(config_path), filebuf);

    const widgets = switch (try cfg.parse(&reg, &bf.buffer, scratch)) {
        .ok => |w| w,
        .err => return error.InvalidConfig,
    };
    if (widgets.len == 0)
        return error.NoWidgets;

    const base = reg.head.ptr;
    const data_len = @intFromPtr(widgets.ptr) - @intFromPtr(base);

    const data = reg.head[0..data_len];
    const widg = reg.head[data_len..][0..inBytes(typ.Widget, widgets.len)];
    const intr = blk: {
        const sp = reg.save(typ.DeciSec, .front);
        var intervals = try reg.allocMany(typ.DeciSec, widgets.len, .front);
        for (widgets, 0..) |*w, i| {
            intervals[i] = w.readInterval(base).set;
        }
        break :blk reg.head[sp.off..][0..inBytes(typ.DeciSec, intervals.len)];
    };
    const wids = blk: {
        const sp = reg.save(typ.Widget.Id, .front);
        var wids = try reg.allocMany(typ.Widget.Id, widgets.len, .front);
        for (widgets, 0..) |*w, i| {
            wids[i] = w.id;
        }
        break :blk reg.head[sp.off..][0..inBytes(typ.Widget.Id, wids.len)];
    };

    const flags: O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    };
    _ = uio.sys_write(try openatZ(AT_FDCWD, data_path, flags, 0o644), data);
    _ = uio.sys_write(try openatZ(AT_FDCWD, widg_path, flags, 0o644), widg);
    _ = uio.sys_write(try openatZ(AT_FDCWD, intr_path, flags, 0o644), intr);
    _ = uio.sys_write(try openatZ(AT_FDCWD, wids_path, flags, 0o644), wids);
}

comptime {
    @export(&main, .{ .name = "main" });
}
pub fn main(argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int {
    real_main(argc, argv) catch |e| {
        _ = uio.sys_writev(2, .{ "dump-config: ", @errorName(e), "\n" });
        return 1;
    };
    return 0;
}
