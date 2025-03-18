const std = @import("std");
const mem = std.mem;

// == public ==================================================================

pub const Hex = struct {
    data: [7]u8 = .{0} ** 7,

    pub fn set(self: *@This(), str: []const u8) bool {
        if (str.len == 0 or mem.eql(u8, str, "default")) {
            @memset(&self.data, 0);
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

        self.data[0] = '#';
        if (ismini) {
            var i: usize = 1;
            for (str[hashash..]) |ch| {
                self.data[i] = ch;
                i += 1;
                self.data[i] = ch;
                i += 1;
            }
        } else {
            @memcpy(self.data[1..], str[hashash..]);
        }
        return true;
    }

    pub fn get(self: *const @This()) ?*const [7]u8 {
        return if (self.data[0] == 0) null else &self.data;
    }
};

pub const ThreshHex = struct {
    thresh: u8,
    hex: Hex,
};

pub const OptColors = struct {
    opt: u8,
    colors: []ThreshHex,
};

pub const Color = union(enum) {
    nocolor,
    default: Hex,
    color: OptColors,

    pub fn getColor(
        self: *const @This(),
        with_checkOptColors: anytype,
    ) ?*const [7]u8 {
        return switch (self.*) {
            .nocolor => null,
            .default => |*hex| hex.get(),
            .color => |oc| with_checkOptColors.checkOptColors(oc),
        };
    }

    pub fn getDefault(self: *const @This()) ?*const [7]u8 {
        return switch (self.*) {
            .nocolor => null,
            .default => |*hex| hex.get(),
            .color => null,
        };
    }
};

pub fn firstColorGEThreshold(value: u64, colors: []const ThreshHex) ?*const [7]u8 {
    var result: ?*const [7]u8 = null;
    for (colors) |*color| {
        if (color.thresh <= value) {
            result = color.hex.get();
        } else {
            break;
        }
    }
    return result;
}

pub fn firstColorEQThreshold(value: u8, colors: []const ThreshHex) ?*const [7]u8 {
    for (colors) |*color| {
        if (value == color.thresh) return color.hex.get();
    }
    return null;
}
