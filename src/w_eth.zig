const std = @import("std");
const cfg = @import("config.zig");
const utl = @import("util.zig");
const typ = @import("type.zig");
const c = utl.c;
const fmt = std.fmt;
const io = std.io;
const os = std.os;

const INET_BUF_SIZE = 4 * "255".len + 3;

var _ioctl_sock: ?os.socket_t = null;
fn getIoctlSocket() os.socket_t {
    if (_ioctl_sock) |sock| {
        return sock;
    } else {
        const sock = os.socket(os.AF.INET, os.SOCK.DGRAM, 0) catch |err| {
            utl.fatal("ETH: socket: {}", .{err});
        };
        _ioctl_sock = sock;
        return sock;
    }
}

fn getInet(
    sock: os.socket_t,
    ifr: *const os.linux.ifreq,
    inetbuf: *[INET_BUF_SIZE]u8,
    ok: *bool,
) []const u8 {
    const e = os.linux.getErrno(os.linux.ioctl(sock, c.SIOCGIFADDR, @intFromPtr(ifr)));
    return switch (e) {
        .SUCCESS => blk: {
            const addr: os.linux.sockaddr.in = @bitCast(ifr.ifru.addr);
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
        .ADDRNOTAVAIL => "<unavailable>",
        .NODEV => "<no device>",
        else => utl.fatal("ETH: inet: {}", .{e}),
    };
}

fn getFlags(sock: os.socket_t, ifr: *const os.linux.ifreq, flagsbuf: *[6]u8) []const u8 {
    // interestingly, the SIOCGIF*P*FLAGS ioctl is not implemented for INET?
    // check switch prong of: v6.6-rc3/source/net/ipv4/af_inet.c#L974
    const e = os.linux.getErrno(os.linux.ioctl(sock, c.SIOCGIFFLAGS, @intFromPtr(ifr)));
    return switch (e) {
        .SUCCESS => blk: {
            var n: u8 = 0;

            if (ifr.ifru.flags & c.IFF_ALLMULTI == c.IFF_ALLMULTI) {
                flagsbuf[n] = 'A';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_BROADCAST == c.IFF_BROADCAST) {
                flagsbuf[n] = 'B';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_MULTICAST == c.IFF_MULTICAST) {
                flagsbuf[n] = 'M';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_PROMISC == c.IFF_PROMISC) {
                flagsbuf[n] = 'P';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_RUNNING == c.IFF_RUNNING) {
                flagsbuf[n] = 'R';
                n += 1;
            }
            if (ifr.ifru.flags & c.IFF_UP == c.IFF_UP) {
                flagsbuf[n] = 'U';
                n += 1;
            }
            break :blk flagsbuf[0..n];
        },
        .NODEV => blk: {
            flagsbuf[0] = '-';
            break :blk flagsbuf[0..1];
        },
        else => utl.fatal("ETH: flags: {}", .{e}),
    };
}

fn checkColor(up: bool, mc: *const cfg.ManyColors) ?*const [7]u8 {
    for (mc.colors) |*color| {
        if (color.thresh == @intFromBool(up))
            return &color.hex;
    }
    return null;
}

pub fn widget(
    stream: anytype,
    cf: *const cfg.ConfigFormat,
    fg: *const cfg.ColorUnion,
    bg: *const cfg.ColorUnion,
) []const u8 {
    const sock = getIoctlSocket();

    var ifr: os.linux.ifreq = undefined;
    const ifname: [:0]u8 = blk: {
        const arg = cf.parts[0];
        if (arg.len >= ifr.ifrn.name.len)
            utl.fatal("ETH: interface name too long: '{s}'", .{arg});
        @memcpy(ifr.ifrn.name[0..arg.len], arg);
        ifr.ifrn.name[arg.len] = '\x00';
        break :blk ifr.ifrn.name[0..arg.len :0];
    };

    var _inetbuf: [INET_BUF_SIZE]u8 = .{0} ** INET_BUF_SIZE;
    var _flagsbuf: [6]u8 = .{0} ** 6;

    var inet: []const u8 = undefined;
    var flags: []const u8 = undefined;
    var state_up: bool = false;

    for (1..cf.nparts - 1) |i| {
        switch (@as(typ.EthOpt, @enumFromInt(cf.opts[i]))) {
            .ifname => {},
            .inet => {
                inet = getInet(sock, &ifr, &_inetbuf, &state_up);
            },
            .flags => {
                flags = getFlags(sock, &ifr, &_flagsbuf);
                if (flags[flags.len - 1] == 'U')
                    state_up = true;
            },
            .state => {},
            .@"-" => unreachable,
        }
    }

    const fg_hex = switch (fg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkColor(state_up, &t),
    };
    const bg_hex = switch (bg.*) {
        .nocolor => null,
        .default => |t| &t.hex,
        .color => |t| checkColor(state_up, &t),
    };

    const writer = stream.writer();

    utl.writeBlockStart(writer, fg_hex, bg_hex);
    utl.writeStr(writer, cf.parts[1]);
    for (1..cf.nparts - 1) |i| {
        switch (@as(typ.EthOpt, @enumFromInt(cf.opts[i]))) {
            .ifname => utl.writeStr(writer, ifname),
            .inet => utl.writeStr(writer, inet),
            .flags => utl.writeStr(writer, flags),
            .state => {
                // neither inet nor flags got polled - get state only
                if (_inetbuf[0] == 0 and _flagsbuf[0] == 0)
                    _ = getInet(sock, &ifr, &_inetbuf, &state_up);
                utl.writeStr(writer, if (state_up) "up" else "down");
            },
            .@"-" => unreachable,
        }
        utl.writeStr(writer, cf.parts[1 + i]);
    }
    return utl.writeBlockEnd_GetWritten(stream);
}
