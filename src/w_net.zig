const std = @import("std");
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const ext = @import("util/ext.zig");
const udiv = @import("util/div.zig");
const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");
const ustr = @import("util/str.zig");

const linux = std.os.linux;

// == private =================================================================

const INET_BUF_SIZE = (4 * "255".len) + (3 * ".".len) + 1;

// I-th bit IF flag abbreviations.
const IFF_BIT_NAMES: [16][]const u8 = .{
    "U",  "B",  "D",  "L", "Pt", "Nt", "R",  "Na",
    "Pr", "Al", "Ma", "S", "Mu", "Po", "Au", "Dy",
};

// Iteration in alphabetical order of IFF_BIT_NAMES.
const IFF_BIT_NAMES_ALPHA_ITER = .{
    9, 14, 1, 2, 15, 3, 10, 12, 7, 5, 13, 8, 4, 6, 11, 0,
};

const IFF_BUF_MAX = blk: {
    var w = 0;
    for (IFF_BIT_NAMES) |e| w += e.len;
    break :blk w + 1;
};

comptime {
    var sum = 0;
    for (IFF_BIT_NAMES_ALPHA_ITER) |e| sum += e;
    if (sum != IFF_BIT_NAMES_ALPHA_ITER.len * (IFF_BIT_NAMES_ALPHA_ITER.len - 1) / 2)
        @compileError("Bad IFF_BIT_NAMES_ALPHA sum");
}

const ColorHandler = struct {
    up: bool,

    pub fn checkPairs(self: *const @This(), ac: color.Active, base: [*]const u8) color.Hex {
        return color.firstColorEQThreshold(@intFromBool(self.up), ac.pairs.get(base));
    }
};

const IFace = struct {
    node: std.SinglyLinkedList.Node,
    name: [linux.IFNAMESIZE]u8,
    fields: [16]u64,

    const rx_bytes = 0;
    const rx_pkts = 1;
    const rx_errs = 2;
    const rx_drop = 3;
    const rx_fifo = 4;
    const rx_frame = 5;
    const rx_compressed = 6;
    const rx_multicast = 7;
    const tx_bytes = 8;
    const tx_pkts = 9;
    const tx_errs = 10;
    const tx_drop = 11;
    const tx_fifo = 12;
    const tx_colls = 13;
    const tx_carrier = 14;
    const tx_compressed = 15;

    comptime {
        const assert = std.debug.assert;
        const off = typ.Options.Net.NETDEV_OFF;
        assert(rx_bytes == @intFromEnum(typ.Options.Net.rx_bytes) - off);
        assert(rx_pkts == @intFromEnum(typ.Options.Net.rx_pkts) - off);
        assert(rx_errs == @intFromEnum(typ.Options.Net.rx_errs) - off);
        assert(rx_drop == @intFromEnum(typ.Options.Net.rx_drop) - off);
        assert(rx_fifo == @intFromEnum(typ.Options.Net.rx_fifo) - off);
        assert(rx_frame == @intFromEnum(typ.Options.Net.rx_frame) - off);
        assert(rx_compressed == @intFromEnum(typ.Options.Net.rx_compressed) - off);
        assert(rx_multicast == @intFromEnum(typ.Options.Net.rx_multicast) - off);
        assert(tx_bytes == @intFromEnum(typ.Options.Net.tx_bytes) - off);
        assert(tx_pkts == @intFromEnum(typ.Options.Net.tx_pkts) - off);
        assert(tx_errs == @intFromEnum(typ.Options.Net.tx_errs) - off);
        assert(tx_drop == @intFromEnum(typ.Options.Net.tx_drop) - off);
        assert(tx_fifo == @intFromEnum(typ.Options.Net.tx_fifo) - off);
        assert(tx_colls == @intFromEnum(typ.Options.Net.tx_colls) - off);
        assert(tx_carrier == @intFromEnum(typ.Options.Net.tx_carrier) - off);
        assert(tx_compressed == @intFromEnum(typ.Options.Net.tx_compressed) - off);
    }

    fn setName(self: *@This(), name: []const u8) void {
        self.name[0..16].* = @splat(0);
        // note: length check omitted
        for (0..name.len) |i| self.name[i] = name[i];
    }
};

const Interfaces = struct {
    list: std.SinglyLinkedList,
    free: std.SinglyLinkedList,

    const empty: Interfaces = .{ .list = .{}, .free = .{} };

    fn allocIf(self: *@This(), reg: *umem.Region) !*IFace {
        var new: *IFace = undefined;
        if (self.free.popFirst()) |free| {
            new = @fieldParentPtr("node", free);
        } else {
            new = try reg.alloc(IFace, .front);
        }
        self.list.prepend(&new.node);
        return new;
    }

    fn freeAll(self: *@This()) void {
        while (self.list.popFirst()) |node| {
            self.free.prepend(node);
        }
    }
};

fn openIoctlSocket() linux.fd_t {
    const ret: isize = @bitCast(linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0));
    if (ret < 0) log.fatalSys(&.{"NET: socket: "}, ret);
    return @intCast(ret);
}

fn getInet(sock: linux.fd_t, ifr: *linux.ifreq, out: *[INET_BUF_SIZE]u8) usize {
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
                    const q, const r = udiv.cMultShiftDivMod(t, 100, 255);
                    const b, const a = ustr.digits2_lut(r);
                    out[i..][0..4].* = .{ '0' | @as(u8, @intCast(q)), b, a, '.' };
                    i += 4;
                } else if (t > 9) {
                    const b, const a = ustr.digits2_lut(t);
                    out[i..][0..3].* = .{ b, a, '.' };
                    i += 3;
                } else {
                    out[i..][0..2].* = .{ '0' | @as(u8, @intCast(t)), '.' };
                    i += 2;
                }
            }
            break :blk i - 1;
        },
        -ext.c.EADDRNOTAVAIL => blk: {
            const s = "<no address>";
            @memcpy(out[0..s.len], s);
            break :blk s.len;
        },
        -ext.c.ENODEV => blk: {
            const s = "<no device>";
            @memcpy(out[0..s.len], s);
            break :blk s.len;
        },
        else => log.fatalSys(&.{"NET: SIOCGIFADDR: "}, ret),
    };
}

fn getFlags(
    sock: linux.fd_t,
    ifr: *linux.ifreq,
    out: *[IFF_BUF_MAX]u8,
) struct { usize, bool } {
    // interestingly, the SIOCGIF*P*FLAGS ioctl is not implemented for INET?
    // check switch prong of: v6.6-rc3/source/net/ipv4/af_inet.c#L974
    const ret: isize = @bitCast(linux.ioctl(sock, linux.SIOCGIFFLAGS, @intFromPtr(ifr)));
    return switch (ret) {
        0 => blk: {
            const up = ifr.ifru.flags.RUNNING;
            const flags: u16 = @bitCast(ifr.ifru.flags);

            var n: usize = 0;
            inline for (IFF_BIT_NAMES_ALPHA_ITER) |i| {
                if (flags & (1 << i) != 0) {
                    const s = IFF_BIT_NAMES[i];
                    @memcpy(out[n..][0..s.len], s);
                    n += s.len;
                }
            }
            break :blk .{ n, up };
        },
        -ext.c.ENODEV => blk: {
            out[0] = '-';
            break :blk .{ 1, false };
        },
        else => log.fatalSys(&.{"NET: SIOCGIFFLAGS: "}, ret),
    };
}

fn parseProcNetDev(
    buf: []const u8,
    ifs: *Interfaces,
    reg: *umem.Region,
) !void {
    var nls: ustr.IndexIterator(u8, '\n') = .init(buf);

    var last: usize = undefined;
    last = nls.next() orelse unreachable;
    last = nls.next() orelse unreachable;
    while (nls.next()) |nl| {
        const line = buf[last + 1 .. nl];
        last = nl;

        var i: usize = 0;
        while (line[i] == ' ') : (i += 1) {}
        var j = i;
        while (line[j] != ':') : (j += 1) {}
        var new_if = try ifs.allocIf(reg);
        new_if.setName(line[i..j]);
        j += 1;

        for (0..new_if.fields.len) |fi| {
            while (line[j] == ' ') : (j += 1) {}
            new_if.fields[fi], j = ustr.atou64ForwardUntilOrEOF(line, j, ' ');
            j += 1;
        }
    }
}

test "/proc/net/dev parser" {
    const t = std.testing;
    const s =
        \\Inter-|   Receive                                                |  Transmit
        \\face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\lo:     100       2    0    0    0     0          0         0      100       2    0    0    0     0       0          0
        \\enp5s0: 2010181142 1586293    0  983    0     0          0      1085 19488012  140072    0    0    0     0       0          0
        \\
    ;
    var buf: [4096]u8 align(16) = undefined;
    @memcpy(buf[0..s.len], s);
    var reg: umem.Region = .init(&buf, "nettest");
    var ifs: Interfaces = .empty;
    try parseProcNetDev(buf[0..s.len], &ifs, &reg);

    const it = ifs.list.first.?;

    const eth: *IFace = @fieldParentPtr("node", it);
    const lo: *IFace = @fieldParentPtr("node", it.next.?);
    try t.expect(it.next.?.next == null);

    try t.expect(eth.fields[0] == 2010181142);
    try t.expect(eth.fields[1] == 1586293);
    try t.expect(eth.fields[2] == 0);
    try t.expect(eth.fields[3] == 983);
    try t.expect(eth.fields[4] == 0);
    try t.expect(eth.fields[5] == 0);
    try t.expect(eth.fields[6] == 0);
    try t.expect(eth.fields[7] == 1085);
    try t.expect(eth.fields[8] == 19488012);
    try t.expect(eth.fields[9] == 140072);
    try t.expect(std.mem.eql(u64, eth.fields[10..16], &@as([6]u64, @splat(0))));

    try t.expect(lo.fields[0] == 100);
    try t.expect(lo.fields[1] == 2);
    try t.expect(std.mem.eql(u64, lo.fields[2..8], &@as([6]u64, @splat(0))));
    try t.expect(lo.fields[8] == 100);
    try t.expect(lo.fields[9] == 2);
    try t.expect(std.mem.eql(u64, lo.fields[10..16], &@as([6]u64, @splat(0))));
}

// == public ==================================================================

pub const State = struct {
    sock: linux.fd_t,
    netdev: ?NetDev,

    const NetDev = struct {
        ifs: [2]Interfaces,
        curr: u32,
        fd: linux.fd_t,
    };

    pub const empty: State = .{ .sock = 0, .netdev = null };

    pub fn init(widgets: []const typ.Widget) State {
        var state: State = .{
            .sock = openIoctlSocket(),
            .netdev = null,
        };
        const wants_netdev = blk: {
            for (widgets) |*w|
                if (w.id == .NET and w.data.NET.opt_mask.netdev != 0)
                    break :blk true;
            break :blk false;
        };
        if (wants_netdev) {
            state.netdev = .{
                .ifs = .{ .empty, .empty },
                .curr = 0,
                .fd = uio.open0("/proc/net/dev") catch |e|
                    log.fatal(&.{ "open: /proc/net/dev: ", @errorName(e) }),
            };
        }
        return state;
    }

    fn getNetdev(self: *const @This(), mask: typ.OptBit) ?*const NetDev {
        return if (mask != 0) &self.netdev.? else null;
    }
};

pub inline fn update(
    reg: *umem.Region,
    state: *State.NetDev,
) error{ NoSpaceLeft, ReadError }!void {
    var buf: [4096]u8 = undefined;
    const n = try uio.pread(state.fd, &buf, 0);
    if (n == buf.len) log.fatal(&.{"NET: /proc/net/dev doesn't fit in 1 page"});

    state.curr ^= 1;
    const iface = &state.ifs[state.curr];
    iface.freeAll();

    try parseProcNetDev(buf[0..n], iface, reg);
}

pub inline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    parts: []const typ.Format.Part,
    base: [*]const u8,
    state: *const State,
) void {
    const wd = w.data.NET;

    var inetbuf: [INET_BUF_SIZE]u8 = undefined;
    var iffbuf: [IFF_BUF_MAX]u8 = undefined;

    var inet_len: usize = 0;
    var iff_len: usize = 0;
    var up = false;

    const enabled = wd.opt_mask.enabled;
    if (enabled.inet)
        inet_len = getInet(state.sock, &wd.ifr, &inetbuf);
    if (enabled.flags or enabled.state or w.fg == .active or w.bg == .active)
        iff_len, up = getFlags(state.sock, &wd.ifr, &iffbuf);

    var new_if: ?*IFace = null;
    var old_if: ?*IFace = null;
    var ifs_match = false;
    if (state.getNetdev(wd.opt_mask.netdev)) |ok| {
        const new, const old = typ.constCurrPrev(Interfaces, &ok.ifs, ok.curr);

        const Hash = @Vector(linux.IFNAMESIZE, u8);
        const cfg_ifname: Hash = wd.ifr.ifrn.name;

        var it = new.list.first;
        while (it) |node| : (it = node.next) {
            const iface: *IFace = @fieldParentPtr("node", node);
            const ifname: Hash = iface.name;
            if (@reduce(.And, ifname == cfg_ifname)) {
                new_if = iface;
                break;
            }
        }
        it = old.list.first;
        while (it) |node| : (it = node.next) {
            const iface: *IFace = @fieldParentPtr("node", node);
            const ifname: Hash = iface.name;
            if (@reduce(.And, ifname == cfg_ifname)) {
                old_if = iface;
                break;
            }
        }
        ifs_match = new_if != null and old_if != null;
    }

    const ch: ColorHandler = .{ .up = up };

    const fg, const bg = w.check(&ch, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (parts) |*part| {
        part.str.writeBytes(writer, base);

        const bit = typ.optBit(part.opt);
        if (bit & wd.opt_mask.string != 0) {
            const SZ = 16;
            const expected = @max(wd.ifr.ifrn.name.len, INET_BUF_SIZE);
            comptime std.debug.assert(expected == SZ);

            if (@max(expected, iff_len) > writer.unusedCapacityLen()) {
                @branchHint(.unlikely);
                break;
            }
            const dst = writer.buffer[writer.end..];
            writer.end += switch (@as(typ.Options.Net.String, @enumFromInt(part.opt))) {
                .arg => advance: {
                    const V = @Vector(SZ, u8);
                    const name: V = wd.ifr.ifrn.name;
                    dst[0..SZ].* = name;
                    const where0: u16 = @bitCast(name == @as(V, @splat(0)));
                    break :advance @ctz(where0);
                },
                .inet => advance: {
                    dst[0..SZ].* = inetbuf;
                    break :advance inet_len;
                },
                .flags => advance: {
                    if (iff_len > expected) {
                        @branchHint(.cold);
                        uio.writeStr(writer, iffbuf[0..iff_len]);
                    } else {
                        dst[0..SZ].* = iffbuf[0..SZ].*;
                    }
                    break :advance iff_len;
                },
                .state => advance: {
                    // Making it branchless gives the compiler some
                    // wild ideas of actually generating code where
                    // `up` is assumed unpredictable, hoisting this
                    // entire calculation up to the function entry.
                    // Not necessary, but pretty cool, so it stays.
                    const i = @intFromBool(up) * @as(usize, 4);
                    dst[0..4].* = "downup  "[i..][0..4].*;
                    break :advance 4 - (i >> 1);
                },
            };
            continue;
        }

        var nu: unt.NumUnit = undefined;
        if (bit & wd.opt_mask.netdev_size != 0) {
            nu = unt.SizeKb(0);
        } else {
            nu = unt.UnitSI(0);
        }
        if (ifs_match) {
            @branchHint(.likely);
            const a = new_if.?.fields[part.opt - typ.Options.Net.NETDEV_OFF];
            const b = old_if.?.fields[part.opt - typ.Options.Net.NETDEV_OFF];

            const value = typ.calc(a, b, w.interval, part.flags);
            if (bit & wd.opt_mask.netdev_size != 0) {
                nu = unt.SizeBytes(value);
            } else {
                nu = unt.UnitSI(value);
            }
        }
        nu.write(writer, part.wopts);
    }
}
