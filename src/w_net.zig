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
    const NR_FIELDS = 16;

    name: [linux.IFNAMESIZE]u8 = .{'-'} ++ (.{0} ** 15),
    fields: [NR_FIELDS]u64 = @splat(0),
    node: std.SinglyLinkedList.Node,

    const FieldType = enum(u64) {
        rx = 0,
        tx = NR_FIELDS / 2,
    };

    pub fn setName(self: *@This(), name: []const u8) void {
        self.name[0..16].* = @splat(0);
        // note: length check omitted
        for (0..name.len) |i| self.name[i] = name[i];
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
                    const q, const r = udiv.cMultShiftDivMod(t, 100, 255);
                    const b, const a = ustr.digits2_lut(r);
                    inetbuf[i..][0..4].* = .{ '0' | @as(u8, @intCast(q)), b, a, '.' };
                    i += 4;
                } else if (t > 9) {
                    const b, const a = ustr.digits2_lut(t);
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
            inline for (IFF_BIT_NAMES_ALPHA_ITER) |i| {
                if (flags & (1 << i) != 0) {
                    const s = IFF_BIT_NAMES[i];
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

        for (0..IFace.NR_FIELDS) |fi| {
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
};

pub fn update(netdev: *NetState.NetDev) void {
    var buf: [4096]u8 = undefined;
    const nr_read = netdev.file.pread(&buf, 0) catch |e| {
        log.fatal(&.{ "NET: pread: ", @errorName(e) });
    };
    if (nr_read == buf.len)
        log.fatal(&.{"NET: /proc/net/dev doesn't fit in 1 page"});

    netdev.swapCurrPrev();
    const new, _ = netdev.getCurrPrev();
    new.freeAll();

    parseProcNetDev(buf[0..nr_read], new) catch |e| {
        log.fatal(&.{ "NET: parse /proc/net/dev: ", @errorName(e) });
    };
}

pub noinline fn widget(
    writer: *uio.Writer,
    w: *const typ.Widget,
    base: [*]const u8,
    state: *const NetState,
) void {
    const wd = w.data.NET;

    var inetbuf: [INET_BUF_SIZE]u8 = @splat(0);
    var iffbuf: [IFF_BUF_MAX]u8 = @splat(0);

    var inet: []const u8 = undefined;
    var flags: []const u8 = undefined;
    var up = false;

    const enabled = wd.opts.enabled;
    if (enabled.inet)
        inet = getInet(state.sock, &wd.ifr, &inetbuf);
    if (enabled.flags or enabled.state or w.fg == .active or w.bg == .active)
        flags = getFlags(state.sock, &wd.ifr, &iffbuf, &up);

    var new_if: ?*IFace = null;
    var old_if: ?*IFace = null;
    var mismatched_ifs: bool = undefined;
    if (state.netdev) |*ok| {
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
        mismatched_ifs = new_if == null or old_if == null;
    }

    const ch: ColorHandler = .{ .up = up };

    const fg, const bg = w.check(ch, base);
    typ.writeWidgetBeg(writer, fg, bg);
    for (wd.format.parts.get(base)) |*part| {
        part.str.writeBytes(writer, base);

        const opt: typ.NetOpt = @enumFromInt(part.opt);
        if (wd.opts.bitOf(part.opt) & wd.opts.str_mask != 0) {
            const str = switch (opt.castTo(typ.NetOpt.StringWriting)) {
                // zig fmt: off
                .arg   => mem.sliceTo(&wd.ifr.ifrn.name, 0),
                .inet  => inet,
                .flags => flags,
                .state => if (up) "up" else "down",
                // zig fmt: on
            };
            uio.writeStr(writer, str);
            continue;
        }

        var nu: unt.NumUnit = undefined;
        if (mismatched_ifs) {
            // New interfaces could have been added or removed in the meantime,
            // always report zero for them instead of some bogus difference.
            nu = if (opt == .rx_bytes or opt == .tx_bytes)
                unt.SizeKb(0)
            else
                unt.UnitSI(0);
        } else {
            const new = new_if.?;
            const old = old_if.?;
            const d = part.diff;
            nu = switch (opt.castTo(typ.NetOpt.NetDevRequired)) {
                // zig fmt: off
                .rx_bytes => unt.SizeBytes(misc.calc(new.bytes(.rx), old.bytes(.rx), d)),
                .rx_pkts  => unt.UnitSI(misc.calc(new.packets(.rx), old.packets(.rx), d)),
                .rx_errs  => unt.UnitSI(misc.calc(new.errs(.rx), old.errs(.rx), d)),
                .rx_drop  => unt.UnitSI(misc.calc(new.drop(.rx), old.drop(.rx), d)),
                .rx_multicast => unt.UnitSI(misc.calc(new.rx_multicast(), old.rx_multicast(), d)),
                .tx_bytes => unt.SizeBytes(misc.calc(new.bytes(.tx), old.bytes(.tx), d)),
                .tx_pkts  => unt.UnitSI(misc.calc(new.packets(.tx), old.packets(.tx), d)),
                .tx_errs  => unt.UnitSI(misc.calc(new.errs(.tx), old.errs(.tx), d)),
                .tx_drop  => unt.UnitSI(misc.calc(new.drop(.tx), old.drop(.tx), d)),
                // zig fmt: on
            };
        }
        nu.write(writer, part.wopts, part.quiet);
    }
    wd.format.last_str.writeBytes(writer, base);
}
