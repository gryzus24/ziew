const std = @import("std");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const fmt = std.fmt;
const io = std.io;
const linux = std.os.linux;

pub fn debugFixedPoint() void {
    const stdout = io.getStdErr().writer();
    for (0..(1 << 12) + 2) |i| {
        const fp = unt.F5608.init(i).div(1 << 8);
        const nu: unt.NumUnit = .{ .n = fp, .u = .si_one };

        fmt.format(stdout, "{d:5} ", .{i}) catch {};
        nu.write(stdout, .none, 0, 0);
        utl.writeStr(stdout, " ");
        nu.write(stdout, .none, 0, 1);
        utl.writeStr(stdout, " ");
        nu.write(stdout, .none, 0, 2);
        utl.writeStr(stdout, " ");
        nu.write(stdout, .none, 0, 3);
        utl.writeStr(stdout, "  ");

        fmt.format(
            stdout,
            "{any:.5}",
            .{@as(f64, @floatFromInt(i)) / (1 << 8)},
        ) catch {};
        utl.writeStr(stdout, "\n");
    }
}

pub fn debugNumUnit() void {
    const stdout = io.getStdOut();
    const stdout_writer = stdout.writer();
    const values: [5]u64 = .{ 948, 9480, 94800, 948000, 9480000 };
    const width_max = 7;
    const precision_max = 3;

    utl.writeStr(stdout_writer, "\n");
    for (values) |val| {
        const nu = unt.UnitSI(val);

        std.debug.print("V {}\n", .{val});
        for (0..width_max + 1) |width| {
            std.debug.print("{} ", .{width});
            for (0..precision_max + 2) |precision| {
                var w: u8 = @intCast(width);
                var p: u8 = @intCast(precision);
                if (p == precision_max + 1)
                    p = unt.PRECISION_AUTO_VALUE;

                const o: unt.NumUnit.WriteOptions = .{
                    .alignment = .right,
                    .width = w,
                    .precision = p,
                };

                utl.writeStr(stdout_writer, "|");
                nu.write(stdout_writer, o);
                utl.writeStr(stdout_writer, "|");

                if (w < 2)
                    w = 2;
                if (p == unt.PRECISION_AUTO_VALUE)
                    p = 0;
                for (0..(width_max - w) + (precision_max - p)) |_| {
                    utl.writeStr(stdout_writer, " ");
                }
                utl.writeStr(stdout_writer, "\t");
            }
            utl.writeStr(stdout_writer, "\n");
        }
    }
}

fn _printColor(prefix: []const u8, co: typ.Color) void {
    const print = std.debug.print;
    switch (co) {
        .nocolor => print("  {s}=.nocolor\n", .{prefix}),
        .default => |t| print("  {s}=.default HEX='{s}'\n", .{ prefix, t.get() orelse "null" }),
        .color => |t| {
            print("  {s}=.color OPT={}\n", .{ prefix, t.opt });
            for (t.colors, 1..) |color, i| {
                print(
                    "    ({}) THRESH={} HEX='{s}'\n",
                    .{ i, color.thresh, color.hex.get() orelse "null" },
                );
            }
        },
    }
}

fn _printFormat(f: typ.Format) void {
    const print = std.debug.print;
    for (f.part_opts, 1..) |po, i| {
        print("  ({}) OPT={} PRECISION={} ALIGNMENT={} PART='{s}'\n", .{
            i,
            po.opt,
            po.precision,
            po.alignment,
            po.part,
        });
    }
    print("      PART_LAST='{s}'\n", .{f.part_last});
}

pub fn debugWidgets(widgets: []const typ.Widget) void {
    const print = std.debug.print;
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

pub fn debugMemoryUsed(reg: *m.Region) void {
    const front, const back = reg.spaceUsed();
    std.debug.print("REGION MEMORY USED\n", .{});
    std.debug.print("  FRONT = {} BACK = {} TOTAL = {}\n", .{ front, back, front + back });
}

pub noinline fn perfEventStart() linux.fd_t { // struct { linux.fd_t, linux.perf_event_attr } {
    var pe: linux.perf_event_attr = .{};

    pe.type = .HARDWARE;
    pe.config = @intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS);
    pe.flags.disabled = true;
    pe.flags.exclude_kernel = true;
    pe.flags.exclude_hv = true;

    const ret = linux.perf_event_open(&pe, 0, 1, -1, 0);
    const rc = @as(isize, @bitCast(ret));
    if (rc < 0)
        utl.fatalFmt("perf_event_open: errno: {}\n", .{rc});

    const fd = @as(linux.fd_t, @intCast(ret));

    _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.RESET, 0);
    _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, 0);

    return fd;
}

pub noinline fn perfEventStop(fd: linux.fd_t) void {
    defer _ = linux.close(fd);

    _ = linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, 0);

    var u64b: [8]u8 = .{0} ** 8;
    _ = linux.read(fd, &u64b, 8);

    std.debug.print("perfEventStop() = {}\n", .{@as(u64, @bitCast(u64b))});
}
