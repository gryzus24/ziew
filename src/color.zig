const std = @import("std");
const mem = std.mem;

pub const Color = struct {
    thresh: u8,
    _hex: [7]u8, // format: [@|#]aabbcc, @ at hex[0] returns null (no color, use default)

    pub fn checkSetHex(self: *@This(), str: []const u8) bool {
        if (str.len == 0 or mem.eql(u8, str, "default")) {
            @memset(&self._hex, '@');
            return true;
        }

        const hashash = @intFromBool(str[0] == '#');
        const ismini = (str.len - hashash) == 3;
        const isnormal = (str.len - hashash) == 6;

        if (!isnormal and !ismini)
            return false;

        for (str[hashash..]) |ch| {
            switch (ch) {
                '0'...'9', 'a'...'f', 'A'...'F' => {},
                else => return false,
            }
        }

        self._hex[0] = '#';
        if (ismini) {
            var i: u8 = 1;
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
};

pub fn firstColorAboveThreshold(value: f64, colors: []const Color) ?*const [7]u8 {
    var result: ?*const [7]u8 = null;
    for (colors) |*color| {
        if (value >= @as(f64, @floatFromInt(color.thresh))) {
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

pub fn colorFromColorUnion(cu: *const ColorUnion, with_checkManyColors: anytype) ?*const [7]u8 {
    return switch (cu.*) {
        .nocolor => null,
        .default => |*t| t.getHex(),
        .color => |t| with_checkManyColors.checkManyColors(t),
    };
}

pub fn defaultColorFromColorUnion(cu: *const ColorUnion) ?*const [7]u8 {
    return switch (cu.*) {
        .nocolor => null,
        .default => |*t| t.getHex(),
        .color => null,
    };
}
