const std = @import("std");
const typ = @import("type.zig");
const mem = std.mem;

pub fn firstColorAboveThreshold(value: u64, colors: []const typ.ThreshHex) ?*const [7]u8 {
    var result: ?*const [7]u8 = null;
    for (colors) |*color| {
        if (color.thresh < value) {
            result = color.hex.get();
        } else {
            break;
        }
    }
    return result;
}

pub fn firstColorEqualThreshold(value: u8, colors: []const typ.ThreshHex) ?*const [7]u8 {
    for (colors) |*color| {
        if (value == color.thresh) return color.hex.get();
    }
    return null;
}
