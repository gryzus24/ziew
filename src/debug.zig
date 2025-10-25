const std = @import("std");
const color = @import("color.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");

const debug = std.debug;
const fs = std.fs;
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
        uio.writeStr(stderr, " ");
        nu.write(stderr, .{ .precision = 1 }, false);
        uio.writeStr(stderr, " ");
        nu.write(stderr, .{ .precision = 2 }, false);
        uio.writeStr(stderr, " ");
        nu.write(stderr, .{ .precision = 3 }, false);
        uio.writeStr(stderr, "  ");

        try stderr.print("{any:.5}", .{@as(f64, @floatFromInt(i)) / (1 << 8)});
        uio.writeStr(stderr, "\n");
        try stderr.flush();
    }
}

pub fn debugNumUnit() !void {
    var buf: [4096]u8 = undefined;
    var writer = fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;

    const values: [14]struct { u64, u8 } = .{
        .{ 9, 1 },
        .{ 94, 2 },
        .{ 948, 3 },
        .{ 9489, 1 },
        .{ 94899, 2 },
        .{ 948999, 3 },
        .{ 99, 2 },
        .{ 999, 3 },
        .{ 1000, 4 },
        .{ 1001, 4 },
        .{ 10240 - 45, 2 },
        .{ 10240 - 44, 2 },
        .{ 10240 - 1, 2 },
        .{ 10240, 2 },
    };
    const width_max: usize = 8;
    const precision_max = 3;

    _ = try stderr.write("\n");
    for (values) |e| {
        const val, const valw = e;
        const nu = unt.SizeKb(val);

        try stderr.print("V {}\n", .{val});
        for (0..width_max + 1) |width| {
            try stderr.print("{} ", .{width});
            for (0..precision_max + 2) |precision| {
                const w: u8 = @intCast(width);
                var p: u8 = @intCast(precision);
                if (p == precision_max + 1)
                    p = unt.PRECISION_VALUE_AUTO;

                var o: unt.NumUnit.WriteOptions = .default;
                o.alignment = .right;
                o.setWidth(w);
                o.setPrecision(p);

                _ = try stderr.write("|");
                nu.write(stderr, o, .{ .negative = false, .quiet = false, .abbreviate = false });
                _ = try stderr.write("|");

                for (0..(width_max - @min(@max(w, valw), unt.PRECISION_VALUE_AUTO))) |_| {
                    _ = try stderr.write(" ");
                }
                _ = try stderr.write("|");
                nu.write(stderr, o, .{ .negative = false, .quiet = false, .abbreviate = true });
                _ = try stderr.write("|");

                for (0..(width_max - @min(@max(w, valw), unt.PRECISION_VALUE_AUTO))) |_| {
                    _ = try stderr.write(" ");
                }
                _ = try stderr.write("\t");
            }
            _ = try stderr.write("\n");
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

pub fn debugMemoryUsed(reg: *umem.Region) !void {
    const print = debug.print;
    const front, const back = reg.spaceUsed();
    print("REGION MEMORY USED\n", .{});
    print("  FRONT = {} BACK = {} TOTAL = {}\n", .{ front, back, front + back });
}

pub noinline fn perfEventStart() [3]linux.fd_t {
    // Zig's std doesn't define `read_format` flags, just use separate events
    // for different counters.
    var peas: [3]linux.perf_event_attr = .{
        .{
            .type = .HARDWARE,
            .config = @intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS),
            .flags = .{
                .disabled = true,
                .exclude_kernel = true,
                .exclude_hv = true,
            },
        },
        .{
            .type = .HARDWARE,
            .config = @intFromEnum(linux.PERF.COUNT.HW.BRANCH_INSTRUCTIONS),
            .flags = .{
                .disabled = true,
                .exclude_kernel = true,
                .exclude_hv = true,
            },
        },
        .{
            .type = .HARDWARE,
            .config = @intFromEnum(linux.PERF.COUNT.HW.BRANCH_MISSES),
            .flags = .{
                .disabled = true,
                .exclude_kernel = true,
                .exclude_hv = true,
            },
        },
    };

    var fds: [3]linux.fd_t = @splat(0);
    for (&peas, 0..) |*pea, i| {
        const ret: isize = @bitCast(linux.perf_event_open(pea, 0, 1, -1, 0));
        if (ret < 0) {
            var writer = fs.File.stderr().writer(&.{});
            const stderr = &writer.interface;
            stderr.print("perf_event_open: errno: {}\n", .{-ret}) catch {};
            linux.exit(1);
        }
        fds[i] = @intCast(ret);
    }

    for (fds) |fd| _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.RESET, 0);
    for (fds) |fd| _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, 0);

    return fds;
}

pub noinline fn perfEventStop(fds: [3]linux.fd_t) void {
    defer {
        for (fds) |fd| uio.close(fd);
    }

    for (fds) |fd| _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, 0);

    var out: [3]u64 = @splat(0);
    for (fds, 0..) |fd, i| {
        var u64a: [8]u8 = @splat(0);
        _ = linux.read(fd, &u64a, 8);
        out[i] = @bitCast(u64a);
    }

    var buf: [64]u8 = undefined;
    var writer = fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;
    stderr.print("perfEventStop() = {any}\n", .{out}) catch {};
    stderr.flush() catch {};
}
