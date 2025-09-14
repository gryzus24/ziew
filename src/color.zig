const std = @import("std");
const m = @import("memory.zig");
const mem = std.mem;

// == public ==================================================================

pub const Hex = struct {
    use: u8,
    hex: [6]u8,

    pub const default: Hex = .{ .use = 0, .hex = undefined };

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

pub fn firstColorGEThreshold(value: u64, pairs: []const Active.Pair) Hex {
    var i: isize = -1;
    for (pairs) |pair| {
        if (pair.thresh <= value) {
            i += 1;
        } else {
            break;
        }
    }
    if (i == -1) return .default;

    return pairs[@as(usize, @intCast(i))].data;
}

pub fn firstColorEQThreshold(value: u8, pairs: []const Active.Pair) Hex {
    for (pairs) |pair| {
        if (pair.thresh == value) return pair.data;
    }
    return .default;
}
