const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const linux = std.os.linux;

pub fn debugFixedPoint() !void {
    var buf: [1024]u8 = undefined;
    var writer = fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;

    for (0..(1 << 12) + 2) |i| {
        const fp = unt.F5608.init(i).div(1 << 8);
        const nu: unt.NumUnit = .{ .n = fp, .u = .kilo };

        try stderr.print("{d:5} ", .{i});
        nu.write(stderr, .{ .precision = 0 }, false);
        utl.writeStr(stderr, " ");
        nu.write(stderr, .{ .precision = 1 }, false);
        utl.writeStr(stderr, " ");
        nu.write(stderr, .{ .precision = 2 }, false);
        utl.writeStr(stderr, " ");
        nu.write(stderr, .{ .precision = 3 }, false);
        utl.writeStr(stderr, "  ");

        try stderr.print("{any:.5}", .{@as(f64, @floatFromInt(i)) / (1 << 8)});
        utl.writeStr(stderr, "\n");
        try stderr.flush();
    }
}

pub fn debugNumUnit() !void {
    var buf: [1024]u8 = undefined;
    var writer = fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;

    const values: [8]u64 = .{ 9, 94, 948, 1023, 9480, 94800, 948000, 9480000 };
    const values_width: [8]u8 = .{ 1, 2, 3, 4, 1, 2, 3, 1 };
    const width_max = 8;
    const precision_max = 3;

    utl.writeStr(stderr, "\n");
    for (values, values_width) |val, valw| {
        const nu = unt.SizeKb(val);

        try stderr.print("V {}\n", .{val});
        for (0..width_max + 1) |width| {
            try stderr.print("{} ", .{width});
            for (0..precision_max + 2) |precision| {
                const w: u8 = @intCast(width);
                var p: u8 = @intCast(precision);
                if (p == precision_max + 1)
                    p = unt.PRECISION_AUTO_VALUE;

                const o: unt.NumUnit.WriteOptions = .{
                    .alignment = .right,
                    .width = w,
                    .precision = p,
                };

                utl.writeStr(stderr, "|");
                nu.write(stderr, o, false);
                utl.writeStr(stderr, "|");

                for (0..(width_max - @max(w, valw))) |_| {
                    utl.writeStr(stderr, " ");
                }
                utl.writeStr(stderr, "\t");
            }
            utl.writeStr(stderr, "\n");
        }
        try stderr.flush();
    }
}

fn _printColor(prefix: []const u8, co: color.Color) void {
    const print = debug.print;
    switch (co) {
        .nocolor => print("  {s}=.nocolor\n", .{prefix}),
        .default => |t| print("  {s}=.default HEX='{s}'\n", .{ prefix, t.get() orelse "null" }),
        .color => |t| {
            print("  {s}=.color OPT={}\n", .{ prefix, t.opt });
            for (t.colors, 1..) |v, i| {
                print(
                    "    ({}) THRESH={} HEX='{s}'\n",
                    .{ i, v.thresh, v.hex.get() orelse "null" },
                );
            }
        },
    }
}

fn _printFormat(f: typ.Format) void {
    const print = debug.print;
    for (f.part_opts, 1..) |po, i| {
        print("  ({}) OPT={} FLAGS={} ALIGNMENT={} WIDTH={} PRECISION={} PART='{s}'\n", .{
            i,
            po.opt,
            po.flags,
            po.wopts.alignment,
            po.wopts.width,
            po.wopts.precision,
            po.str,
        });
    }
    print("      PART_LAST='{s}'\n", .{f.part_last});
}

pub fn debugWidgets(widgets: []const typ.Widget) !void {
    const print = debug.print;
    for (widgets) |*w| {
        print("WIDGET={s} INTERVAL={}\n", .{ @tagName(w.wid), w.interval });
        switch (w.wid) {
            .TIME => |wd| {
                print("  FORMAT='{s}' FG=HEX='{s}' BG=HEX='{s}'\n", .{
                    wd.format,
                    wd.fg.get() orelse "null",
                    wd.bg.get() orelse "null",
                });
            },
            .MEM => |wd| {
                _printFormat(wd.format);
                _printColor("FG", wd.fg);
                _printColor("BG", wd.bg);
            },
            .CPU => |wd| {
                _printFormat(wd.format);
                _printColor("FG", wd.fg);
                _printColor("BG", wd.bg);
            },
            .DISK => |wd| {
                _printFormat(wd.format);
                _printColor("FG", wd.fg);
                _printColor("BG", wd.bg);
            },
            .NET => |wd| {
                _printFormat(wd.format);
                _printColor("FG", wd.fg);
                _printColor("BG", wd.bg);
            },
            .BAT => |wd| {
                _printFormat(wd.format);
                _printColor("FG", wd.fg);
                _printColor("BG", wd.bg);
            },
            .READ => |wd| {
                _printFormat(wd.format);
                print("      FG=HEX='{s}' BG=HEX='{s}'\n", .{
                    wd.fg.get() orelse "null",
                    wd.bg.get() orelse "null",
                });
            },
        }
    }
}

pub fn debugMemoryUsed(reg: *m.Region) !void {
    const print = debug.print;
    const front, const back = reg.spaceUsed();
    print("REGION MEMORY USED\n", .{});
    print("  FRONT = {} BACK = {} TOTAL = {}\n", .{ front, back, front + back });
}

pub noinline fn perfEventStart() linux.fd_t { // struct { linux.fd_t, linux.perf_event_attr } {
    var pe: linux.perf_event_attr = .{};

    pe.type = .HARDWARE;
    pe.config = @intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS);
    pe.flags.disabled = true;
    pe.flags.exclude_kernel = true;
    pe.flags.exclude_hv = true;

    const ret: isize = @bitCast(linux.perf_event_open(&pe, 0, 1, -1, 0));
    if (ret < 0)
        utl.fatalFmt("perf_event_open: errno: {}\n", .{-ret});

    const fd: linux.fd_t = @intCast(ret);

    _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.RESET, 0);
    _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, 0);

    return fd;
}

pub noinline fn perfEventStop(fd: linux.fd_t) void {
    defer _ = linux.close(fd);

    _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, 0);

    var u64b: [8]u8 = .{0} ** 8;
    _ = linux.read(fd, &u64b, 8);

    debug.print("perfEventStop() = {}\n", .{@as(u64, @bitCast(u64b))});
}
