const std = @import("std");
const mem = std.mem;

pub const Color = struct {
    thresh: u8,

    // format: [@|#]aabbcc, @ at _hex[0] returns null (no color, use default)
    _hex: [7]u8,

    pub fn init(thresh: u8, hex: []const u8) !@This() {
        var inst: Color = .{ .thresh = thresh, ._hex = undefined };
        if (!inst.checkSetHex(hex)) return error.BadHex;
        return inst;
    }

    pub fn checkSetHex(self: *@This(), str: []const u8) bool {
        if (str.len == 0 or mem.eql(u8, str, "default")) {
            @memset(&self._hex, '@');
            return true;
        }

        const hashash = @intFromBool(str[0] == '#');
        const ismini = (str.len - hashash) == 3;
        const isnormal = (str.len - hashash) == 6;

        if (!isnormal and !ismini) return false;

        for (str[hashash..]) |ch| switch (ch) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        };

        self._hex[0] = '#';
        if (ismini) {
            var i: usize = 1;
            for (str[hashash..]) |ch| {
                self._hex[i] = ch;
                i += 1;
                self._hex[i] = ch;
                i += 1;
            }
        } else {
            @memcpy(self._hex[1..], str[hashash..]);
        }
        return true;
    }

    pub fn getHex(self: *const @This()) ?*const [7]u8 {
        return if (self._hex[0] == '@') null else &self._hex;
    }
};

pub const ManyColors = struct {
    opt: u8,
    colors: []const Color,
};

pub const ColorUnion = union(enum) {
    nocolor,
    default: Color,
    color: ManyColors,

    pub fn getColor(self: *const @This(), with_checkManyColors: anytype) ?*const [7]u8 {
        return switch (self.*) {
            .nocolor => null,
            .default => |*t| t.getHex(),
            .color => |t| with_checkManyColors.checkManyColors(t),
        };
    }

    pub fn getDefault(self: *const @This()) ?*const [7]u8 {
        return switch (self.*) {
            .nocolor => null,
            .default => |*t| t.getHex(),
            .color => null,
        };
    }
};

pub fn firstColorAboveThreshold(value: u64, colors: []const Color) ?*const [7]u8 {
    var result: ?*const [7]u8 = null;
    for (colors) |*color| {
        if (value >= color.thresh) {
            result = color.getHex();
        } else {
            break;
        }
    }
    return result;
}

pub fn firstColorEqualThreshold(value: u8, colors: []const Color) ?*const [7]u8 {
    for (colors) |*color| {
        if (value == color.thresh)
            return color.getHex();
    }
    return null;
}
