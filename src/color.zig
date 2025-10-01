const std = @import("std");
const m = @import("memory.zig");
const mem = std.mem;

// == public ==================================================================

pub const Hex = struct {
    use: u8,
    _: u8 = 0,
    hex: [6]u8,

    pub const default: Hex = .{ .use = 0, .hex = @splat(0) };

    pub fn init(hex: [6]u8) @This() {
        return .{ .use = 1, .hex = hex };
    }
};

pub const Active = struct {
    opt: u8,
    pairs: m.MemSlice(Pair),

    pub const Pair = struct {
        thresh: u8,
        data: Hex,
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
        if (pair.thresh > value) break;
        i += 1;
    }
    if (i != 0)
        return pairs[i - 1].data;

    return .default;
}

pub inline fn firstColorEQThreshold(value: u8, pairs: []const Active.Pair) Hex {
    for (pairs) |pair| {
        if (pair.thresh == value) return pair.data;
    }
    return .default;
}
