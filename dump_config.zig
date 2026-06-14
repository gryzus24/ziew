const std = @import("std");

const cfg = @import("src/config.zig");
const typ = @import("src/type.zig");
const uio = @import("src/util/io.zig");
const umem = @import("src/util/mem.zig");

const AT_FDCWD = std.posix.AT.FDCWD;
const O = std.os.linux.O;
const openatZ = std.posix.openatZ;

var bss: [0x3a00]u8 align(16) = undefined;

fn real_main(argc: c_int, argv: [*]const [*:0]const u8) !void {
    const args = argv[0..@intCast(argc)];
    if (args.len < 5) return error.InvalidArgs;

    const config_path = argv[1];
    const data_path = argv[2];
    const widg_path = argv[3];
    const intr_path = argv[4];

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

    const data_beg = @intFromPtr(base);
    const widg_beg = @intFromPtr(widgets.ptr);

    const data_len = widg_beg - data_beg;

    const data = reg.head[0..data_len];
    const widg = reg.head[data_len..][0 .. @sizeOf(typ.Widget) * widgets.len];
    const intr = blk: {
        const sp = reg.save(typ.DeciSec, .front);
        var intervals = try reg.allocMany(typ.DeciSec, widgets.len, .front);
        for (widgets, 0..) |*w, i| {
            intervals[i] = w.getDataConst(base).interval.set;
        }
        break :blk reg.head[sp.off..][0 .. @sizeOf(typ.DeciSec) * intervals.len];
    };

    const flags: O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    };
    _ = uio.sys_write(try openatZ(AT_FDCWD, data_path, flags, 0o644), data);
    _ = uio.sys_write(try openatZ(AT_FDCWD, widg_path, flags, 0o644), widg);
    _ = uio.sys_write(try openatZ(AT_FDCWD, intr_path, flags, 0o644), intr);
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
