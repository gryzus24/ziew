const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;
const fmt = std.fmt;
const io = std.io;
const linux = std.os.linux;

// == private =================================================================

const INET_BUF_SIZE = (4 * "255".len) + 3;

const ColorHandler = struct {
    up: bool,

    pub fn checkOptColors(self: @This(), oc: typ.OptColors) ?*const [7]u8 {
        return color.firstColorEqualThreshold(@intFromBool(self.up), oc.colors);
    }
};

// the std.os.linux.E enum adds over 15kB of bloat to the executable,
// we used to utilize libc constants to fight against this, but it is
// ultimately futile - embrace the bloat.
inline fn errnoInt(r: usize) isize {
    return @as(isize, @bitCast(r));
}

fn openIoctlSocket() linux.fd_t {
    const ret = errnoInt(linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0));
    if (ret <= 0) utl.fatalFmt("NET: socket errno: {}", .{ret});
    return @as(linux.fd_t, @intCast(ret));
}

fn getInet(
    sock: linux.fd_t,
    ifr: *const linux.ifreq,
    inetbuf: *[INET_BUF_SIZE]u8,
) []const u8 {
    const e = errnoInt(linux.ioctl(sock, c.SIOCGIFADDR, @intFromPtr(ifr)));
    return switch (e) {
        0 => blk: {
            const addr: linux.sockaddr.in = @bitCast(ifr.ifru.addr);
            var inetfbs = io.fixedBufferStream(inetbuf);
            const writer = inetfbs.writer();

            utl.writeInt(writer, @intCast((addr.addr >> 0) & 0xff));
            utl.writeStr(writer, ".");
            utl.writeInt(writer, @intCast((addr.addr >> 8) & 0xff));
            utl.writeStr(writer, ".");
            utl.writeInt(writer, @intCast((addr.addr >> 16) & 0xff));
            utl.writeStr(writer, ".");
            utl.writeInt(writer, @intCast((addr.addr >> 24) & 0xff));
            break :blk inetfbs.getWritten();
        },
        -c.EADDRNOTAVAIL => "<no address>",
        -c.ENODEV => "<no device>",
        else => utl.fatalFmt("NET: inet errno: {}", .{e}),
    };
}

fn getFlags(
    sock: linux.fd_t,
    ifr: *const linux.ifreq,
    flagsbuf: *[6]u8,
    up: *bool,
) []const u8 {
    // interestingly, the SIOCGIF*P*FLAGS ioctl is not implemented for INET?
    // check switch prong of: v6.6-rc3/source/net/ipv4/af_inet.c#L974
    const e = errnoInt(linux.ioctl(sock, c.SIOCGIFFLAGS, @intFromPtr(ifr)));
    return switch (e) {
        0 => blk: {
            var n: usize = 0;

            if (ifr.ifru.flags & c.IFF_ALLMULTI > 0) {
                flagsbuf[n] = 'A';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_BROADCAST > 0) {
                flagsbuf[n] = 'B';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_MULTICAST > 0) {
                flagsbuf[n] = 'M';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_PROMISC > 0) {
                flagsbuf[n] = 'P';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_RUNNING > 0) {
                up.* = true;
                flagsbuf[n] = 'R';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_UP > 0) {
                flagsbuf[n] = 'U';
                n += 1;
            }
            break :blk flagsbuf[0..n];
        },
        -c.ENODEV => blk: {
            flagsbuf[0] = '-';
            break :blk flagsbuf[0..1];
        },
        else => utl.fatalFmt("NET: flags errno: {}", .{e}),
    };
}

// == public ==================================================================

pub const WidgetData = struct {
    ifr: linux.ifreq,
    ifname_len: u8,
    format: typ.Format = .{},
    fg: typ.Color = .nocolor,
    bg: typ.Color = .nocolor,

    pub fn init(reg: *m.Region, arg: []const u8) !*WidgetData {
        var ifr: linux.ifreq = undefined;
        if (arg.len >= ifr.ifrn.name.len)
            utl.fatal(&.{ "NET: interface name too long: ", arg });

        const retptr = try reg.frontAlloc(WidgetData);

        @memcpy(ifr.ifrn.name[0..arg.len], arg);
        ifr.ifrn.name[arg.len] = 0;
        retptr.* = .{ .ifr = ifr, .ifname_len = @as(u8, @intCast(arg.len)) };

        return retptr;
    }
};

pub fn widget(stream: anytype, w: *const typ.Widget) []const u8 {
    const Static = struct {
        var sock: linux.fd_t = 0;
    };
    if (Static.sock == 0)
        Static.sock = openIoctlSocket();

    const wd = w.wid.NET;

    var _inetbuf: [INET_BUF_SIZE]u8 = .{0} ** INET_BUF_SIZE;
    var _flagsbuf: [6]u8 = .{0} ** 6;

    var inet: []const u8 = undefined;
    var flags: []const u8 = undefined;
    var up: bool = false;

    const INET = comptime (1 << @intFromEnum(typ.NetOpt.inet));
    const FLAGS = comptime (1 << @intFromEnum(typ.NetOpt.flags));
    const STATE = comptime (1 << @intFromEnum(typ.NetOpt.state));
    var demands: u8 = 0;

    if (@typeInfo(typ.NetOpt).Enum.fields.len >= @bitSizeOf(@TypeOf(demands)))
        @compileError("bump demands bitfield size");

    for (wd.format.part_opts) |*part|
        demands |= @as(u8, 1) << @intCast(part.opt);

    if (demands & INET > 0)
        inet = getInet(Static.sock, &wd.ifr, &_inetbuf);
    if (demands & (FLAGS | STATE) > 0 or wd.fg == .color or wd.bg == .color)
        flags = getFlags(Static.sock, &wd.ifr, &_flagsbuf, &up);

    const ch: ColorHandler = .{ .up = up };

    utl.writeBlockStart(stream, wd.fg.getColor(ch), wd.bg.getColor(ch));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(stream, part.part);
        utl.writeStr(
            stream,
            switch (@as(typ.NetOpt, @enumFromInt(part.opt))) {
                // zig fmt: off
                .arg   => wd.ifr.ifrn.name[0..wd.ifname_len],
                .inet  => inet,
                .flags => flags,
                .state => if (up) "up" else "down",
                // zig fmt: on
            },
        );
    }
    utl.writeStr(stream, wd.format.part_last);
    return utl.writeBlockEnd_GetWritten(stream);
}
