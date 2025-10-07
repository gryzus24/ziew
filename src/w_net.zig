const std = @import("std");
const c = @import("c.zig").c;
const color = @import("color.zig");
const log = @import("log.zig");
const typ = @import("type.zig");
const unt = @import("unit.zig");

const misc = @import("util/misc.zig");
const udiv = @import("util/div.zig");
const uio = @import("util/io.zig");
const umem = @import("util/mem.zig");
const ustr = @import("util/str.zig");

const fs = std.fs;
const linux = std.os.linux;
const mem = std.mem;

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

    pub fn checkPairs(self: @This(), ac: color.Active, base: [*]const u8) color.Hex {
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
        const off = typ.NetOpt.NETDEV_OPTS_OFF;
        assert(IFace.rx_bytes == @intFromEnum(typ.NetOpt.rx_bytes) - off);
        assert(IFace.rx_pkts == @intFromEnum(typ.NetOpt.rx_pkts) - off);
        assert(IFace.rx_errs == @intFromEnum(typ.NetOpt.rx_errs) - off);
        assert(IFace.rx_drop == @intFromEnum(typ.NetOpt.rx_drop) - off);
        assert(IFace.rx_fifo == @intFromEnum(typ.NetOpt.rx_fifo) - off);
        assert(IFace.rx_frame == @intFromEnum(typ.NetOpt.rx_frame) - off);
        assert(IFace.rx_compressed == @intFromEnum(typ.NetOpt.rx_compressed) - off);
        assert(IFace.rx_multicast == @intFromEnum(typ.NetOpt.rx_multicast) - off);
        assert(IFace.tx_bytes == @intFromEnum(typ.NetOpt.tx_bytes) - off);
        assert(IFace.tx_pkts == @intFromEnum(typ.NetOpt.tx_pkts) - off);
        assert(IFace.tx_errs == @intFromEnum(typ.NetOpt.tx_errs) - off);
        assert(IFace.tx_drop == @intFromEnum(typ.NetOpt.tx_drop) - off);
        assert(IFace.tx_fifo == @intFromEnum(typ.NetOpt.tx_fifo) - off);
        assert(IFace.tx_colls == @intFromEnum(typ.NetOpt.tx_colls) - off);
        assert(IFace.tx_carrier == @intFromEnum(typ.NetOpt.tx_carrier) - off);
        assert(IFace.tx_compressed == @intFromEnum(typ.NetOpt.tx_compressed) - off);
    }

    pub fn setName(self: *@This(), name: []const u8) void {
        self.name[0..16].* = @splat(0);
        // note: length check omitted
        for (0..name.len) |i| self.name[i] = name[i];
    }
};

const Interfaces = struct {
    reg: *umem.Region,
    list: std.SinglyLinkedList = .{},
    free: std.SinglyLinkedList = .{},

    pub fn allocIf(self: *@This()) !*IFace {
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
        -c.EADDRNOTAVAIL => blk: {
            const s = "<no address>";
            @memcpy(out[0..s.len], s);
            break :blk s.len;
        },
        -c.ENODEV => blk: {
            const s = "<no device>";
            @memcpy(out[0..s.len], s);
            break :blk s.len;
        },
        else => log.fatal(&.{"NET: SIOCGIFADDR"}),
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
        -c.ENODEV => blk: {
            out[0] = '-';
            break :blk .{ 1, false };
        },
        else => log.fatal(&.{"NET: SIOCGIFFLAGS"}),
    };
}

fn parseProcNetDev(buf: []const u8, ifs: *Interfaces) !void {
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
        var new_if = try ifs.allocIf();
        new_if.setName(line[i..j]);
        j += 1;

        for (0..new_if.fields.len) |fi| {
            while (line[j] == ' ') : (j += 1) {}
            new_if.fields[fi] = ustr.atou64ForwardUntilOrEOF(line, &j, ' ');
            j += 1;
        }
    }
}

// == public ==================================================================

pub const NetState = struct {
    sock: linux.fd_t,
    netdev: ?NetDev,

    const NetDev = struct {
        ifs: [2]Interfaces,
        curr: usize,
        file: fs.File,

        fn getCurrPrev(self: *const @This()) struct { *Interfaces, *Interfaces } {
            const i = self.curr;
            return .{ @constCast(&self.ifs[i]), @constCast(&self.ifs[i ^ 1]) };
        }

        fn swapCurrPrev(self: *@This()) void {
            self.curr ^= 1;
        }
    };

    pub const empty: NetState = .{ .sock = 0, .netdev = null };

    pub fn init(reg: *umem.Region, widgets: []const typ.Widget) NetState {
        var state: NetState = .{
            .sock = openIoctlSocket(),
            .netdev = null,
        };
        const wants_netdev = blk: {
            for (widgets) |*w|
                if (w.id == .NET and w.data.NET.opts.netdev_mask != 0)
                    break :blk true;
            break :blk false;
        };
        if (wants_netdev) {
            const a: Interfaces = .{ .reg = reg };
            const b: Interfaces = .{ .reg = reg };
            state.netdev = .{
                .ifs = .{ a, b },
                .curr = 0,
                .file = fs.cwd().openFileZ("/proc/net/dev", .{}) catch |e|
                    log.fatal(&.{ "open: /proc/net/dev: ", @errorName(e) }),
            };
        }
        return state;
    }

    pub fn getNetdev(self: *const @This(), mask: typ.OptBit) ?*const NetDev {
        return if (mask != 0) &self.netdev.? else null;
    }
};

pub fn update(netdev: *NetState.NetDev) void {
    var buf: [4096]u8 = undefined;
    const nr_read = netdev.file.pread(&buf, 0) catch |e|
        log.fatal(&.{ "NET: pread: ", @errorName(e) });
    if (nr_read == buf.len)
        log.fatal(&.{"NET: /proc/net/dev doesn't fit in 1 page"});

    netdev.swapCurrPrev();
    const new, _ = netdev.getCurrPrev();
    new.freeAll();

    parseProcNetDev(buf[0..nr_read], new) catch |e|
        log.fatal(&.{ "NET: parse /proc/net/dev: ", @errorName(e) });
}

pub noinline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    base: [*]const u8,
    state: *const NetState,
) void {
    const wd = w.data.NET;

    var inetbuf: [INET_BUF_SIZE]u8 = undefined;
    var iffbuf: [IFF_BUF_MAX]u8 = undefined;

    var inet_len: usize = 0;
    var iff_len: usize = 0;
    var up = false;

    const enabled = wd.opts.enabled;
    if (enabled.inet)
        inet_len = getInet(state.sock, &wd.ifr, &inetbuf);
    if (enabled.flags or enabled.state or w.fg == .active or w.bg == .active)
        iff_len, up = getFlags(state.sock, &wd.ifr, &iffbuf);

    var new_if: ?*IFace = null;
    var old_if: ?*IFace = null;
    var ifs_match = false;
    if (state.getNetdev(wd.opts.netdev_mask)) |ok| {
        const new, const old = ok.getCurrPrev();

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

    const fg, const bg = w.check(ch, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.NetOpt = @enumFromInt(part.opt);
        const bit = typ.optBit(part.opt);

        if (bit & wd.opts.string_mask != 0) {
            const SZ = 16;
            const expected = @max(wd.ifr.ifrn.name.len, INET_BUF_SIZE);
            comptime std.debug.assert(expected == SZ);

            if (@max(expected, iff_len) > writer.unusedCapacityLen()) {
                @branchHint(.unlikely);
                break;
            }
            const dst = writer.buffer[writer.end..];
            writer.end += switch (opt.castTo(typ.NetOpt.StringOpts)) {
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
        if (bit & wd.opts.netdev_size_mask != 0) {
            nu = unt.SizeKb(0);
        } else {
            nu = unt.UnitSI(0);
        }
        if (ifs_match) {
            @branchHint(.likely);
            const a = new_if.?.fields[part.opt - typ.NetOpt.NETDEV_OPTS_OFF];
            const b = old_if.?.fields[part.opt - typ.NetOpt.NETDEV_OPTS_OFF];

            if (bit & wd.opts.netdev_size_mask != 0) {
                nu = unt.SizeBytes(misc.calc(a, b, part.diff));
            } else {
                nu = unt.UnitSI(misc.calc(a, b, part.diff));
            }
        }
        nu.write(writer, part.wopts, part.quiet);
    }
    wd.format.last_str.writeBytes(writer, base);
}
