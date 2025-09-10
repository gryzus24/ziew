const std = @import("std");
const mem = std.mem;

// == public ==================================================================

pub const Color = union(enum) {
    default: Data,
    active: Active,

    pub fn get(self: *const @This(), indirect: anytype) Data {
        return switch (self.*) {
            .default => |hex| hex,
            .active => |a| indirect.checkPairs(a),
        };
    }

    pub const Data = union(enum) {
        default,
        hex: [6]u8,
    };

    pub const Active = struct {
        opt: u8,
        pairs: []Pair,

        pub const Pair = struct {
            thresh: u8,
            data: Data,
        };
    };

    pub const NoopIndirect = struct {
        pub fn checkPairs(self: @This(), ac: Active) Data {
            _ = self;
            _ = ac;
            return .default;
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

pub fn firstColorGEThreshold(value: u64, pairs: []const Color.Active.Pair) Color.Data {
    var i: isize = -1;
    for (pairs) |*pair| {
        if (pair.thresh <= value) {
            i += 1;
        } else {
            break;
        }
    }
    if (i == -1) return .default;

    return pairs[@as(usize, @intCast(i))].data;
}

pub fn firstColorEQThreshold(value: u8, pairs: []const Color.Active.Pair) Color.Data {
    for (pairs) |*pair| {
        if (pair.thresh == value) return pair.data;
    }
    return .default;
}
