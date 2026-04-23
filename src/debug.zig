const std = @import("std");
const unt = @import("unit.zig");

const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");

const linux = std.os.linux;

pub fn debugFixedPoint() !void {
    var buf: [1024]u8 = undefined;
    var writer: uio.Writer = .fixed(&buf);

    var opts: unt.NumUnit.WriteOptions = .default;
    for (0..(1 << 12) + 2) |i| {
        const fp = unt.F5608.init(i).div(1 << 8);
        const nu: unt.NumUnit = .{ .n = fp, .u = .kilo };

        std.debug.print("{d:5} ", .{i});

        opts.setPrecision(0);
        nu.write(&writer, opts);
        uio.writeStr(&writer, " ");

        opts.setPrecision(1);
        nu.write(&writer, opts);
        uio.writeStr(&writer, " ");

        opts.setPrecision(2);
        nu.write(&writer, opts);
        uio.writeStr(&writer, " ");

        opts.setPrecision(3);
        nu.write(&writer, opts);
        uio.writeStr(&writer, "  ");

        std.debug.print(
            "{s}{any:.5}\n",
            .{ writer.buffered(), @as(f64, @floatFromInt(i)) / (1 << 8) },
        );
        writer.end = 0;
    }
}

pub fn debugNumUnit() !void {
    var buf: [4096]u8 = undefined;
    var writer: uio.Writer = .fixed(&buf);

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

    std.debug.print("\n", .{});
    for (values) |e| {
        const val, const valw = e;
        const nu = unt.SizeKb(val);

        std.debug.print("V {}\n", .{val});
        for (0..width_max + 1) |width| {
            std.debug.print("{} ", .{width});
            for (0..precision_max + 2) |precision| {
                const w: u8 = @intCast(width);
                var p: u8 = @intCast(precision);
                if (p == precision_max + 1)
                    p = unt.PRECISION_VALUE_AUTO;

                var o: unt.NumUnit.WriteOptions = .default;
                o.alignment = .right;
                o.setWidth(w);
                o.setPrecision(p);

                uio.writeStr(&writer, "|");
                nu.write(&writer, o);
                uio.writeStr(&writer, "|");

                for (0..(width_max - @min(@max(w, valw), unt.PRECISION_VALUE_AUTO))) |_| {
                    uio.writeStr(&writer, " ");
                }
                uio.writeStr(&writer, "|");
                nu.write(&writer, o);
                uio.writeStr(&writer, "|");

                for (0..(width_max - @min(@max(w, valw), unt.PRECISION_VALUE_AUTO))) |_| {
                    uio.writeStr(&writer, " ");
                }
                uio.writeStr(&writer, "\t");
            }
            std.debug.print("{s}\n", .{writer.buffered()});
            writer.end = 0;
        }
    }
}

pub fn debugMemoryUsed(reg: *umem.Region) !void {
    const front, const back = reg.spaceUsed();
    std.debug.print("REGION MEMORY USED\n", .{});
    std.debug.print("  FRONT = {} BACK = {} TOTAL = {}\n", .{ front, back, front + back });
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
            std.debug.print("perf_event_open: errno: {}\n", .{-ret});
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

    std.debug.print("perfEventStop() = {any}\n", .{out});
}
