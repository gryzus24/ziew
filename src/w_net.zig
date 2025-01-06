const std = @import("std");
const color = @import("color.zig");
const m = @import("memory.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");
const utl = @import("util.zig");
const c = utl.c;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const linux = std.os.linux;
const mem = std.mem;

// == private =================================================================

const INET_BUF_SIZE = (4 * "255".len) + 3;

const ColorHandler = struct {
    up: bool,

    pub fn checkOptColors(self: @This(), oc: typ.OptColors) ?*const [7]u8 {
        return color.firstColorEqualThreshold(@intFromBool(self.up), oc.colors);
    }
};

const IFace = struct {
    const FIELDS_MAX = 16;

    name: [linux.IFNAMESIZE]u8 = .{'-'} ++ (.{0} ** 15),
    fields: [FIELDS_MAX]u64 = .{0} ** FIELDS_MAX,

    const FieldType = enum(u64) {
        rx = 0,
        tx = FIELDS_MAX / 2,
    };

    pub fn setName(self: *@This(), name: []const u8) void {
        // note: length check omitted
        @memset(self.name[0..], 0);
        @memcpy(self.name[0..name.len], name);
    }

    pub fn bytes(self: *const @This(), comptime t: FieldType) u64 {
        return self.fields[0 + @intFromEnum(t)];
    }
    pub fn packets(self: *const @This(), comptime t: FieldType) u64 {
        return self.fields[1 + @intFromEnum(t)];
    }
    pub fn errs(self: *const @This(), comptime t: FieldType) u64 {
        return self.fields[2 + @intFromEnum(t)];
    }
    pub fn drop(self: *const @This(), comptime t: FieldType) u64 {
        return self.fields[3 + @intFromEnum(t)];
    }
    pub fn fifo(self: *const @This(), comptime t: FieldType) u64 {
        return self.fields[4 + @intFromEnum(t)];
    }
    pub fn rx_frame(self: *const @This()) u64 {
        return self.fields[5];
    }
    pub fn rx_compressed(self: *const @This()) u64 {
        return self.fields[6];
    }
    pub fn rx_multicast(self: *const @This()) u64 {
        return self.fields[7];
    }
    pub fn tx_colls(self: *const @This()) u64 {
        return self.fields[5 + @intFromEnum(.tx)];
    }
    pub fn tx_carrier(self: *const @This()) u64 {
        return self.fields[6 + @intFromEnum(.tx)];
    }
    pub fn tx_compressed(self: *const @This()) u64 {
        return self.fields[7 + @intFromEnum(.tx)];
    }
};

const NetDev = struct {
    nr_ifs: usize = 0,
    ifs: [8]IFace = .{.{}} ** 8,
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

fn parseProcNetDev(buf: []const u8, netdev: *NetDev) void {
    var lines = mem.tokenizeScalar(u8, buf, '\n');
    _ = lines.next() orelse unreachable;
    _ = lines.next() orelse unreachable;
    var if_indx: usize = 0;
    while (lines.next()) |line| {
        var i: usize = 0;
        while (line[i] == ' ') : (i += 1) {}
        var j = i;
        while (line[j] != ':') : (j += 1) {}
        netdev.ifs[if_indx].setName(line[i..j]);
        j += 1; // skip ':'
        for (0..IFace.FIELDS_MAX) |field_indx| {
            while (line[j] == ' ') : (j += 1) {}
            netdev.ifs[if_indx].fields[field_indx] = utl.atou64ForwardUntilOrEOF(line, &j, ' ');
        }
        if_indx += 1;
        // potentially annoying limitation if working with Docker, CAN or anything
        // that requires creating a lot of interfaces... will be lifted.
        if (if_indx == 8)
            utl.fatal(&.{"NET: too many interfaces"});
    }
    netdev.nr_ifs = if_indx;
}

// == public ==================================================================

pub const WidgetData = struct {
    ifr: linux.ifreq,
    format: typ.Format = .{},
    fg: typ.Color = .nocolor,
    bg: typ.Color = .nocolor,

    pub fn init(reg: *m.Region, arg: []const u8) !*WidgetData {
        var ifr: linux.ifreq = undefined;
        if (arg.len >= ifr.ifrn.name.len)
            utl.fatal(&.{ "NET: interface name too long: ", arg });

        const retptr = try reg.frontAlloc(WidgetData);

        @memset(ifr.ifrn.name[0..], 0);
        @memcpy(ifr.ifrn.name[0..arg.len], arg);
        retptr.* = .{ .ifr = ifr };

        return retptr;
    }
};

pub const NetState = struct {
    left: NetDev = .{},
    right: NetDev = .{},
    left_newest: bool = false,

    proc_net_dev: fs.File,

    pub fn init(widgets: []const typ.Widget) ?NetState {
        const proc_net_dev_required = blk: {
            for (widgets) |*w| {
                if (w.wid == .NET) {
                    const wd = w.wid.NET;
                    for (wd.format.part_opts) |part| {
                        const opt = @as(typ.NetOpt, @enumFromInt(part.opt));
                        if (opt.requiresProcNetDev()) break :blk true;
                    }
                }
            }
            break :blk false;
        };
        if (proc_net_dev_required) {
            return .{
                .proc_net_dev = fs.cwd().openFileZ("/proc/net/dev", .{}) catch |e| {
                    utl.fatal(&.{ "open: /proc/net/dev: ", @errorName(e) });
                },
            };
        }
        return null;
    }

    fn getNewOldPtrs(self: *const @This()) struct { *NetDev, *NetDev } {
        return if (self.left_newest)
            .{ @constCast(&self.left), @constCast(&self.right) }
        else
            .{ @constCast(&self.right), @constCast(&self.left) };
    }

    fn newStateFlip(self: *@This()) struct { *NetDev, *NetDev } {
        self.left_newest = !self.left_newest;
        return self.getNewOldPtrs();
    }
};

pub fn update(state: *NetState) void {
    var buf: [4096]u8 = undefined;
    const nread = state.proc_net_dev.pread(&buf, 0) catch |e| {
        utl.fatal(&.{ "NET: pread: ", @errorName(e) });
    };
    if (nread == buf.len)
        utl.fatal(&.{"NET: /proc/net/dev doesn't fit in 1 page"});

    const new, _ = state.newStateFlip();

    parseProcNetDev(buf[0..nread], new);
}

pub fn widget(stream: anytype, state: *const ?NetState, w: *const typ.Widget) []const u8 {
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
    var up = false;

    const INET = comptime (1 << @intFromEnum(typ.NetOpt.inet));
    const FLAGS = comptime (1 << @intFromEnum(typ.NetOpt.flags));
    const STATE = comptime (1 << @intFromEnum(typ.NetOpt.state));
    var demands: u32 = 0;

    if (@typeInfo(typ.NetOpt).Enum.fields.len >= @bitSizeOf(@TypeOf(demands)))
        @compileError("bump demands bitfield size");

    for (wd.format.part_opts) |*part|
        demands |= @as(@TypeOf(demands), 1) << @intCast(part.opt);

    if (demands & INET > 0)
        inet = getInet(Static.sock, &wd.ifr, &_inetbuf);
    if (demands & (FLAGS | STATE) > 0 or wd.fg == .color or wd.bg == .color)
        flags = getFlags(Static.sock, &wd.ifr, &_flagsbuf, &up);

    var new_if_wrapped: ?*IFace = null;
    var old_if_wrapped: ?*IFace = null;
    if (state.*) |*ok| {
        const new, const old = ok.getNewOldPtrs();
        new_if_wrapped = &new.ifs[0];
        old_if_wrapped = &old.ifs[0];

        const n = @min(new.nr_ifs, old.nr_ifs);
        for (new.ifs[0..n]) |*iface| {
            if (mem.eql(u8, &wd.ifr.ifrn.name, &iface.name)) {
                new_if_wrapped = iface;
                break;
            }
        }
        for (old.ifs[0..n]) |*iface| {
            if (mem.eql(u8, &wd.ifr.ifrn.name, &iface.name)) {
                old_if_wrapped = iface;
                break;
            }
        }
    }

    const ch: ColorHandler = .{ .up = up };

    utl.writeBlockStart(stream, wd.fg.getColor(ch), wd.bg.getColor(ch));
    for (wd.format.part_opts) |*part| {
        utl.writeStr(stream, part.part);

        const opt = @as(typ.NetOpt, @enumFromInt(part.opt));
        if (opt.requiresSocket()) {
            const str = switch (opt.castTo(typ.NetOpt.SocketRequired)) {
                // zig fmt: off
                .arg   => mem.sliceTo(&wd.ifr.ifrn.name, 0),
                .inet  => inet,
                .flags => flags,
                .state => if (up) "up" else "down",
                // zig fmt: on
            };
            utl.writeStr(stream, str);
            continue;
        }
        const new_if: *const IFace = new_if_wrapped orelse continue;
        const old_if: *const IFace = old_if_wrapped orelse continue;

        var nu: unt.NumUnit = undefined;

        // new interfaces could have been added or removed in the meantime,
        // always report zero for them instead of some bogus difference.
        if (!mem.eql(u8, &new_if.name, &old_if.name)) {
            nu = if (opt == .rx_bytes or opt == .tx_bytes)
                unt.SizeKb(0)
            else
                unt.UnitSI(0);
        } else {
            nu = switch (opt.castTo(typ.NetOpt.ProcNetDevRequired)) {
                // zig fmt: off
                .rx_bytes => unt.SizeBytes(new_if.bytes(.rx) - old_if.bytes(.rx)),
                .rx_pkts  => unt.UnitSI(new_if.packets(.rx) - old_if.packets(.rx)),
                .rx_errs  => unt.UnitSI(new_if.errs(.rx) - old_if.errs(.rx)),
                .rx_drop  => unt.UnitSI(new_if.drop(.rx) - old_if.drop(.rx)),
                .rx_multicast => unt.UnitSI(new_if.rx_multicast() - old_if.rx_multicast()),
                .tx_bytes => unt.SizeBytes(new_if.bytes(.tx) - old_if.bytes(.tx)),
                .tx_pkts  => unt.UnitSI(new_if.packets(.tx) - old_if.packets(.tx)),
                .tx_errs  => unt.UnitSI(new_if.errs(.tx) - old_if.errs(.tx)),
                .tx_drop  => unt.UnitSI(new_if.drop(.tx) - old_if.drop(.tx)),
                // zig fmt: on
            };
        }
        nu.write(stream, part.wopts);
    }
    utl.writeStr(stream, wd.format.part_last);
    return utl.writeBlockEnd_GetWritten(stream);
}
