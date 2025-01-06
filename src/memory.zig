const std = @import("std");
const utl = @import("util.zig");
const io = std.io;
const linux = std.os.linux;
const mem = std.mem;
const posix = std.posix;

// == private =================================================================

fn printAlloc(reg: *Region, s: []const u8, comptime T: type, nmemb: usize, pad: usize) void {
    const front, const back = reg.spaceUsed();
    const total_size = @sizeOf(T) * nmemb + pad;
    const writer = utl.stderr.writer();
    _ = writer.print(
        "F={:<4} B={:<4} T={:<5} | ({s}) PAD={} N={:<4} SZ={:<4} TSZ={:<4} {}\n",
        .{ front, back, front + back, s, pad, nmemb, @sizeOf(T), total_size, T },
    ) catch {};
}

// == public ==================================================================

pub const TRACE_ALLOCATIONS = false;

pub const SOME_MMAP_ADDR: [*]align(mem.page_size) u8 = @ptrFromInt(0x600000000000);

/// Region of address space that grows in both directions; from lower to higher
/// address - front - and from higher to lower (stack-like) - back.
///
/// Front is used for allocating objects that cannot be allocated all at once
/// (they are pushed back vector-style into the next available address);
/// - strings,
/// - arrays of out of band data.
///
/// Back is used for allocating objects of known size or small "controlling"
/// objects whose primary function is to hold references to out of band
/// data that is allocated at the front.
///
/// NOTE: Functions that take `Region` as an argument should not make
///       permanent allocations on the back as it may break the continuity
///       of callers' back allocations.
pub const Region = struct {
    /// Pointer to the beginning of the address space.
    head: []align(16) u8,

    /// Current front index - initially `0`.
    front: usize,

    /// Current back index - initially `head.len`.
    back: usize,

    pub const SavePoint = usize;
    pub const AllocError = error{NoSpaceLeft};

    pub fn init(bytes: []align(16) u8) Region {
        return .{ .head = bytes, .front = 0, .back = bytes.len };
    }

    pub fn frontAllocMany(self: *@This(), comptime T: type, nmemb: usize) AllocError![]T {
        const pad = (~self.front +% 1) & (@alignOf(T) - 1);
        const aligned_off = self.front + pad;
        const avail = self.back -| aligned_off;

        if (TRACE_ALLOCATIONS)
            printAlloc(self, "FRONT", T, nmemb, pad);

        if (nmemb > avail / @sizeOf(T)) return error.NoSpaceLeft;
        const alloc_size = @sizeOf(T) * nmemb;

        self.front = aligned_off + alloc_size;

        return @alignCast(mem.bytesAsSlice(
            T,
            self.head[aligned_off..][0..alloc_size],
        ));
    }

    pub fn frontAlloc(self: *@This(), comptime T: type) AllocError!*T {
        return @ptrCast(try self.frontAllocMany(T, 1));
    }

    pub fn backAllocMany(self: *@This(), comptime T: type, nmemb: usize) ![]T {
        const pad = self.back & (@alignOf(T) - 1);
        const aligned_off = self.back - pad;
        const avail = aligned_off -| self.front;

        if (TRACE_ALLOCATIONS)
            printAlloc(self, "BACK ", T, nmemb, pad);

        if (nmemb > avail / @sizeOf(T)) return error.NoSpaceLeft;
        const alloc_size = @sizeOf(T) * nmemb;

        self.back = aligned_off - alloc_size;

        return @alignCast(mem.bytesAsSlice(
            T,
            self.head[self.back..][0..alloc_size],
        ));
    }

    pub fn backAlloc(self: *@This(), comptime T: type) AllocError!*T {
        return @ptrCast(try self.backAllocMany(T, 1));
    }

    pub fn frontSave(self: *const @This(), comptime T: type) SavePoint {
        return mem.alignForward(usize, self.front, @alignOf(T));
    }

    pub fn frontRestore(self: *@This(), sp: SavePoint) void {
        self.front = sp;
    }

    pub fn backSave(self: *const @This(), comptime T: type) SavePoint {
        return mem.alignBackward(usize, self.back, @alignOf(T));
    }

    pub fn backRestore(self: *@This(), sp: SavePoint) void {
        self.back = sp;
    }

    pub fn frontWriteStr(self: *@This(), str: []const u8) AllocError![]const u8 {
        const retptr = try self.frontAllocMany(u8, str.len);
        @memcpy(retptr, str);
        return retptr;
    }

    pub fn frontWriteStrZ(self: *@This(), str: []const u8) AllocError![:0]const u8 {
        const retptr = try self.frontAllocMany(u8, str.len + 1);
        @memcpy(retptr[0..str.len], str);
        retptr[str.len] = 0;
        return retptr[0..str.len :0];
    }

    pub fn frontPushVec(self: *@This(), vec: anytype) !*@TypeOf(vec.*[0]) {
        const T = @TypeOf(vec.*[0]);
        var retptr = try self.frontAllocMany(T, 1);
        if (vec.len == 0) {
            vec.* = retptr;
        } else {
            vec.len += 1;
        }
        return &retptr[0];
    }

    pub fn backPushVec(self: *@This(), vec: anytype) !*@TypeOf(vec.*[0]) {
        const T = @TypeOf(vec.*[0]);
        var retptr = try self.backAllocMany(T, 1);
        if (vec.len > 0) {
            retptr.len = vec.len + 1;
            mem.copyForwards(T, retptr, vec.*);
        }
        vec.* = retptr;
        return &vec.*[vec.len - 1];
    }

    pub fn slice(self: *const @This(), comptime T: type, start: SavePoint, n: usize) []T {
        return mem.bytesAsSlice(T, self.head[start..][0 .. @sizeOf(T) * n]);
    }

    pub fn spaceLeft(self: *const @This(), comptime T: type) usize {
        const f = self.frontSave(T);
        const b = self.backSave(T);
        if (f > b) return 0;
        return b - f;
    }

    pub fn spaceUsed(self: *const @This()) struct { usize, usize } {
        return .{ self.front, self.head.len - self.back };
    }
};
