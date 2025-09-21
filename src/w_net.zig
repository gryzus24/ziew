const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
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

const INET_BUF_SIZE = (4 * "255".len) + (3 * ".".len) + 1;

// i-th bit IF flag abbreviation.
const IFF_NAME: [16][]const u8 = .{
    "U",  "B",  "D",  "L", "Pt", "Nt", "R",  "Na",
    "Pr", "Al", "Ma", "S", "Mu", "Po", "Au", "D",
};
const IFF_BUF_MAX = blk: {
    var w = 0;
    for (IFF_NAME) |e| {
        w += e.len;
    }
    break :blk w + 1;
};

// Iteration in alphabetical order of IFF_NAME over IF flag bits.
const IFF_ALPHA_ORDER: [16]u16 = .{
    9, 14, 1, 2, 15, 3, 10, 12, 7, 5, 13, 8, 4, 6, 11, 0,
};
comptime {
    var w = 0;
    for (IFF_ALPHA_ORDER) |e| {
        w += e;
    }
    if (w != IFF_ALPHA_ORDER.len * (IFF_ALPHA_ORDER.len - 1) / 2)
        @compileError("Bad IFF_ALPHA_ORDER sum");
}

const ColorHandler = struct {
    up: bool,

    pub fn checkPairs(self: @This(), ac: color.Active, base: [*]const u8) color.Hex {
        return color.firstColorEQThreshold(@intFromBool(self.up), ac.pairs.get(base));
    }
};

const IFace = struct {
    const NR_FIELDS = 16;

    name: [linux.IFNAMESIZE]u8 = .{'-'} ++ (.{0} ** 15),
    fields: [NR_FIELDS]u64 = @splat(0),
    node: std.SinglyLinkedList.Node,

    const FieldType = enum(u64) {
        rx = 0,
        tx = NR_FIELDS / 2,
    };

    pub fn setName(self: *@This(), name: []const u8) void {
        // note: length check omitted
        @memset(self.name[0..], 0);
        @memcpy(self.name[0..name.len], name);
    }

    pub fn bytes(self: @This(), comptime t: FieldType) u64 {
        return self.fields[0 + @intFromEnum(t)];
    }
    pub fn packets(self: @This(), comptime t: FieldType) u64 {
        return self.fields[1 + @intFromEnum(t)];
    }
    pub fn errs(self: @This(), comptime t: FieldType) u64 {
        return self.fields[2 + @intFromEnum(t)];
    }
    pub fn drop(self: @This(), comptime t: FieldType) u64 {
        return self.fields[3 + @intFromEnum(t)];
    }
    pub fn fifo(self: @This(), comptime t: FieldType) u64 {
        return self.fields[4 + @intFromEnum(t)];
    }
    pub fn rx_frame(self: @This()) u64 {
        return self.fields[5];
    }
    pub fn rx_compressed(self: @This()) u64 {
        return self.fields[6];
    }
    pub fn rx_multicast(self: @This()) u64 {
        return self.fields[7];
    }
    pub fn tx_colls(self: @This()) u64 {
        return self.fields[5 + @intFromEnum(.tx)];
    }
    pub fn tx_carrier(self: @This()) u64 {
        return self.fields[6 + @intFromEnum(.tx)];
    }
    pub fn tx_compressed(self: @This()) u64 {
        return self.fields[7 + @intFromEnum(.tx)];
    }
};

const NetDev = struct {
    reg: *m.Region,
    list: IFaceList = .{},
    free: IFaceList = .{},

    const IFaceList = std.SinglyLinkedList;

    pub fn newIf(self: *@This()) !*IFace {
        var new: *IFace = undefined;
        if (self.free.popFirst()) |free| {
            new = @fieldParentPtr("node", free);
        } else {
            new = try self.reg.frontAlloc(IFace);
        }
        self.list.prepend(&new.node);
        return new;
    }

    pub fn freeAll(self: *@This()) void {
        while (self.list.popFirst()) |node| {
            self.free.prepend(node);
        }
    }
};

fn openIoctlSocket() linux.fd_t {
    const ret: isize = @bitCast(linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0));
    if (ret < 0) log.fatal(&.{"NET: socket"});
    return @intCast(ret);
}

fn getInet(
    sock: linux.fd_t,
    ifr: *const linux.ifreq,
    inetbuf: *[INET_BUF_SIZE]u8,
) []const u8 {
    // the std.os.linux.E enum adds over 10kB of bloat to the executable,
    // use libc constants instead - we don't need pretty errno names.
    const ret: isize = @bitCast(linux.ioctl(sock, linux.SIOCGIFADDR, @intFromPtr(ifr)));
    return switch (ret) {
        0 => blk: {
            const addr: linux.sockaddr.in = @bitCast(ifr.ifru.addr);

            const tuplets: [4]u32 = .{
                (addr.addr >> 0) & 0xff,
                (addr.addr >> 8) & 0xff,
                (addr.addr >> 16) & 0xff,
                (addr.addr >> 24) & 0xff,
            };

            var i: usize = 0;
            for (tuplets) |t| {
                if (t > 99) {
                    const b, const a = utl.digits2_lut(t % 100);
                    inetbuf[i..][0..4].* = .{ '0' | @as(u8, @intCast(t / 100)), b, a, '.' };
                    i += 4;
                } else if (t > 9) {
                    const b, const a = utl.digits2_lut(t);
                    inetbuf[i..][0..3].* = .{ b, a, '.' };
                    i += 3;
                } else {
                    inetbuf[i..][0..2].* = .{ '0' | @as(u8, @intCast(t)), '.' };
                    i += 2;
                }
            }
            break :blk inetbuf[0 .. i - 1];
        },
        -c.EADDRNOTAVAIL => "<no address>",
        -c.ENODEV => "<no device>",
        else => log.fatal(&.{"NET: SIOCGIFADDR"}),
    };
}

fn getFlags(
    sock: linux.fd_t,
    ifr: *const linux.ifreq,
    iffbuf: *[IFF_BUF_MAX]u8,
    up: *bool,
) []const u8 {
    // interestingly, the SIOCGIF*P*FLAGS ioctl is not implemented for INET?
    // check switch prong of: v6.6-rc3/source/net/ipv4/af_inet.c#L974
    const ret: isize = @bitCast(linux.ioctl(sock, linux.SIOCGIFFLAGS, @intFromPtr(ifr)));
    return switch (ret) {
        0 => blk: {
            if (ifr.ifru.flags.RUNNING)
                up.* = true;

            const flags: u16 = @bitCast(ifr.ifru.flags);

            var n: usize = 0;
            inline for (IFF_ALPHA_ORDER) |i| {
                if (flags & (1 << i) > 0) {
                    const s = IFF_NAME[i];
                    @memcpy(iffbuf[n..][0..s.len], s);
                    n += s.len;
                }
            }
            break :blk iffbuf[0..n];
        },
        -c.ENODEV => blk: {
            iffbuf[0] = '-';
            break :blk iffbuf[0..1];
        },
        else => log.fatal(&.{"NET: SIOCGIFFLAGS"}),
    };
}

fn parseProcNetDev(buf: []const u8, netdev: *NetDev) !void {
    var lines = mem.tokenizeScalar(u8, buf, '\n');
    _ = lines.next() orelse unreachable;
    _ = lines.next() orelse unreachable;
    while (lines.next()) |line| {
        var i: usize = 0;
        while (line[i] == ' ') : (i += 1) {}
        var j = i;
        while (line[j] != ':') : (j += 1) {}
        var new_if = try netdev.newIf();
        new_if.setName(line[i..j]);
        j += 1; // skip ':'
        for (0..IFace.NR_FIELDS) |field_indx| {
            while (line[j] == ' ') : (j += 1) {}
            new_if.fields[field_indx] = utl.atou64ForwardUntilOrEOF(line, &j, ' ');
        }
    }
}

// == public ==================================================================

pub const NetState = struct {
    left: NetDev,
    right: NetDev,
    left_newest: bool = false,

    proc_net_dev: fs.File,

    pub fn init(reg: *m.Region, widgets: []const typ.Widget) ?NetState {
        const proc_net_dev_required = blk: {
            for (widgets) |*w| {
                if (w.wid == .NET) {
                    const wd = w.wid.NET;
                    for (wd.format.parts.get(reg.head.ptr)) |*part| {
                        const opt: typ.NetOpt = @enumFromInt(part.opt);
                        if (opt.requiresProcNetDev()) break :blk true;
                    }
                }
            }
            break :blk false;
        };
        if (proc_net_dev_required) {
            return .{
                .proc_net_dev = fs.cwd().openFileZ("/proc/net/dev", .{}) catch |e| {
                    log.fatal(&.{ "open: /proc/net/dev: ", @errorName(e) });
                },
                .left = .{ .reg = reg },
                .right = .{ .reg = reg },
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
    const nr_read = state.proc_net_dev.pread(&buf, 0) catch |e| {
        log.fatal(&.{ "NET: pread: ", @errorName(e) });
    };
    if (nr_read == buf.len)
        log.fatal(&.{"NET: /proc/net/dev doesn't fit in 1 page"});

    const new, _ = state.newStateFlip();
    new.freeAll();

    parseProcNetDev(buf[0..nr_read], new) catch |e| {
        log.fatal(&.{ "NET: parse /proc/net/dev: ", @errorName(e) });
    };
}

pub fn widget(
    writer: *io.Writer,
    state: *const ?NetState,
    w: *const typ.Widget,
    base: [*]const u8,
) []const u8 {
    const Static = struct {
        var sock: linux.fd_t = 0;
    };
    if (Static.sock == 0)
        Static.sock = openIoctlSocket();

    const wd = w.wid.NET;

    var _inetbuf: [INET_BUF_SIZE]u8 = @splat(0);
    var _iffbuf: [IFF_BUF_MAX]u8 = @splat(0);

    var inet: []const u8 = undefined;
    var flags: []const u8 = undefined;
    var up = false;

    const INET = comptime (1 << @intFromEnum(typ.NetOpt.inet));
    const FLAGS = comptime (1 << @intFromEnum(typ.NetOpt.flags));
    const STATE = comptime (1 << @intFromEnum(typ.NetOpt.state));
    var demands: u32 = 0;

    if (@typeInfo(typ.NetOpt).@"enum".fields.len >= @bitSizeOf(@TypeOf(demands)))
        @compileError("bump demands bitfield size");

    for (wd.format.parts.get(base)) |*part|
        demands |= @as(@TypeOf(demands), 1) << @intCast(part.opt);

    if (demands & INET > 0)
        inet = getInet(Static.sock, &wd.ifr, &_inetbuf);
    if (demands & (FLAGS | STATE) > 0 or w.fg == .active or w.bg == .active)
        flags = getFlags(Static.sock, &wd.ifr, &_iffbuf, &up);

    var new_if: ?*IFace = null;
    var old_if: ?*IFace = null;
    if (state.*) |*ok| {
        const new, const old = ok.getNewOldPtrs();

        var it = new.list.first;
        while (it) |node| : (it = node.next) {
            const iface: *IFace = @fieldParentPtr("node", node);
            if (mem.eql(u8, &wd.ifr.ifrn.name, &iface.name)) {
                new_if = iface;
                break;
            }
        }
        it = old.list.first;
        while (it) |node| : (it = node.next) {
            const iface: *IFace = @fieldParentPtr("node", node);
            if (mem.eql(u8, &wd.ifr.ifrn.name, &iface.name)) {
                old_if = iface;
                break;
            }
        }
    }

    const ch: ColorHandler = .{ .up = up };

    const fg, const bg = w.check(ch, base);
    utl.writeBlockBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        utl.writeStr(writer, part.str.get(base));

        const opt: typ.NetOpt = @enumFromInt(part.opt);
        if (opt.requiresSocket()) {
            const str = switch (opt.castTo(typ.NetOpt.SocketRequired)) {
                // zig fmt: off
                .arg   => mem.sliceTo(&wd.ifr.ifrn.name, 0),
                .inet  => inet,
                .flags => flags,
                .state => if (up) "up" else "down",
                // zig fmt: on
            };
            utl.writeStr(writer, str);
            continue;
        }
        var nu: unt.NumUnit = undefined;

        // new interfaces could have been added or removed in the meantime,
        // always report zero for them instead of some bogus difference.
        if (new_if == null or old_if == null) {
            nu = if (opt == .rx_bytes or opt == .tx_bytes)
                unt.SizeKb(0)
            else
                unt.UnitSI(0);
        } else {
            const new = new_if.?;
            const old = old_if.?;
            const d = part.diff;
            nu = switch (opt.castTo(typ.NetOpt.ProcNetDevRequired)) {
                // zig fmt: off
                .rx_bytes => unt.SizeBytes(utl.calc(new.bytes(.rx), old.bytes(.rx), d)),
                .rx_pkts  => unt.UnitSI(utl.calc(new.packets(.rx), old.packets(.rx), d)),
                .rx_errs  => unt.UnitSI(utl.calc(new.errs(.rx), old.errs(.rx), d)),
                .rx_drop  => unt.UnitSI(utl.calc(new.drop(.rx), old.drop(.rx), d)),
                .rx_multicast => unt.UnitSI(utl.calc(new.rx_multicast(), old.rx_multicast(), d)),
                .tx_bytes => unt.SizeBytes(utl.calc(new.bytes(.tx), old.bytes(.tx), d)),
                .tx_pkts  => unt.UnitSI(utl.calc(new.packets(.tx), old.packets(.tx), d)),
                .tx_errs  => unt.UnitSI(utl.calc(new.errs(.tx), old.errs(.tx), d)),
                .tx_drop  => unt.UnitSI(utl.calc(new.drop(.tx), old.drop(.tx), d)),
                // zig fmt: on
            };
        }
        nu.write(writer, part.wopts, part.quiet);
    }
    utl.writeStr(writer, wd.format.last_str.get(base));
    return utl.writeBlockEnd(writer);
}
