const std = @import("std");
const cfg = @import("config.zig");
const color = @import("color.zig");
const typ = @import("type.zig");
const utl = @import("util.zig");
const c = utl.c;
const fmt = std.fmt;
const io = std.io;
const linux = std.os.linux;

const INET_BUF_SIZE = (4 * "255".len) + 3;

// the std.os.linux.E enum adds over 15kB of bloat to the executable,
// use the libc errno constants instead.
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
    ok: *bool,
) []const u8 {
    const e = errnoInt(linux.ioctl(sock, c.SIOCGIFADDR, @intFromPtr(ifr)));
    return switch (e) {
        0 => blk: {
            const addr: linux.sockaddr.in = @bitCast(ifr.ifru.addr);
            var inetfbs = io.fixedBufferStream(inetbuf);
            const writer = inetfbs.writer();

            ok.* = true;
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
    ok: *bool,
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
                ok.* = true;
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

const ColorHandler = struct {
    isup: bool,

    pub fn checkManyColors(self: @This(), mc: color.ManyColors) ?*const [7]u8 {
        return color.firstColorEqualThreshold(@intFromBool(self.isup), mc.colors);
    }
};

pub fn widget(
    stream: anytype,
    wf: *const cfg.WidgetFormat,
    fg: *const color.ColorUnion,
    bg: *const color.ColorUnion,
) []const u8 {
    const Static = struct {
        var sock: linux.fd_t = 0;
    };
    if (Static.sock == 0)
        Static.sock = openIoctlSocket();

    var ifr: linux.ifreq = undefined;
    const ifname = wf.parts[0];
    _ = utl.zeroTerminate(&ifr.ifrn.name, ifname) orelse utl.fatal(
        &.{ "NET: interface name too long: ", ifname },
    );

    var _inetbuf: [INET_BUF_SIZE]u8 = .{0} ** INET_BUF_SIZE;
    var _flagsbuf: [6]u8 = .{0} ** 6;

    var inet: []const u8 = undefined;
    var flags: []const u8 = undefined;
    var isup: bool = false;
    var wants_state: bool = false;

    for (wf.iterOpts()[1..]) |*opt| {
        switch (@as(typ.NetOpt, @enumFromInt(opt.opt))) {
            .ifname => {},
            .inet => inet = getInet(Static.sock, &ifr, &_inetbuf, &isup),
            .flags => flags = getFlags(Static.sock, &ifr, &_flagsbuf, &isup),
            .state => wants_state = true,
            .@"-" => unreachable,
        }
    }
    // neither inet nor flags got polled - poll for isup only
    if (wants_state and _inetbuf[0] == 0 and _flagsbuf[0] == 0)
        _ = getInet(Static.sock, &ifr, &_inetbuf, &isup);

    const ch: ColorHandler = .{ .isup = isup };

    utl.writeBlockStart(stream, fg.getColor(ch), bg.getColor(ch));
    utl.writeStr(stream, wf.parts[1]);
    for (wf.iterOpts()[1..], wf.iterParts()[2..]) |*opt, *part| {
        const str = switch (@as(typ.NetOpt, @enumFromInt(opt.opt))) {
            .ifname => ifname,
            .inet => inet,
            .flags => flags,
            .state => if (isup) "up" else "down",
            .@"-" => unreachable,
        };
        utl.writeStr(stream, str);
        utl.writeStr(stream, part.*);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
