const std = @import("std");
const umem = @import("util/mem.zig");

// == public ==================================================================

pub const Hex = struct {
    _priv: u8 = undefined,
    tag: Tag,
    hex: [6]u8,

    pub const Tag = enum(u8) {
        empty,
        fg,
        bg,
    };

    pub const empty: Hex = .{ .tag = .empty, .hex = @splat(0) };

    pub fn init(tag: Tag, hex: [6]u8) @This() {
        return .{ .tag = tag, .hex = hex };
    }
};

pub const Active = struct {
    opt: u8,
    pct: bool,
    pairs: umem.MemSlice(Pair),

    pub const Pair = struct {
        inner: Hex,

        pub fn init(tag: Hex.Tag, hex: [6]u8, _thresh: u8) @This() {
            var ret: Hex = .init(tag, hex);
            ret._priv = _thresh;
            return .{ .inner = ret };
        }

        pub fn initEmpty(_thresh: u8) @This() {
            var ret: Hex = .empty;
            ret._priv = _thresh;
            return .{ .inner = ret };
        }

        pub fn thresh(self: @This()) u8 {
            return self.inner._priv;
        }
    };
};

pub fn acceptHex(str: []const u8) ?[6]u8 {
    if (str.len == 0) return null;

    const hashash = @intFromBool(str[0] == '#');
    const ismini = (str.len - hashash) == 3;
    const isnormal = (str.len - hashash) == 6;

    if (!isnormal and !ismini) return null;

    for (str[hashash..]) |ch| switch (ch) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return null,
    };

    var hex: [6]u8 = undefined;

    if (ismini) {
        const a = str[hashash..];
        hex[0] = a[0];
        hex[1] = a[0];
        hex[2] = a[1];
        hex[3] = a[1];
        hex[4] = a[2];
        hex[5] = a[2];
    } else {
        @memcpy(&hex, str[hashash..]);
    }
    return hex;
}

pub inline fn firstColorGEThreshold(value: u64, pairs: []const Active.Pair) Hex {
    var i: usize = 0;
    for (pairs) |pair| {
        if (pair.thresh() > value) break;
        i += 1;
    }
    if (i != 0)
        return pairs[i - 1].inner;

    return .empty;
}

pub inline fn firstColorEQThreshold(value: u8, pairs: []const Active.Pair) Hex {
    for (pairs) |pair| {
        if (pair.thresh() == value) return pair.inner;
    }
    return .empty;
}
