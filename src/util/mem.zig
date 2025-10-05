const builtin = @import("builtin");
const std = @import("std");
const uio = @import("io.zig");
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;

// == private =================================================================

fn printAlloc(reg: *Region, str: []const u8, comptime T: type, nmemb: usize, pad: usize) void {
    const front, const back = reg.spaceUsed();
    const total_size = @sizeOf(T) * nmemb + pad;

    var writer = fs.File.stderr().writer(&.{});
    const stderr = &writer.interface;

    stderr.print(
        "{s:<8} F={:<4} B={:<4} T={:<5} | ({s}) PAD={} N={:<4} SZ={:<4} TSZ={:<4} {}\n",
        .{ reg.name, front, back, front + back, str, pad, nmemb, @sizeOf(T), total_size, T },
    ) catch {};
}

// == public ==================================================================

pub fn memcpyZ(dst: []u8, src: []const u8) ?[:0]const u8 {
    if (src.len >= dst.len) return null;
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return dst[0..src.len :0];
}

pub const TRACE_ALLOCATIONS = false;

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

    /// Region's name - for debugging purposes.
    name: []const u8,

    pub const SavePoint = struct {
        where: Where,
        off: usize,

        pub const Where = enum(u8) { front, back };
    };
    pub const AllocError = error{NoSpaceLeft};

    pub fn init(bytes: []align(16) u8, name: []const u8) Region {
        return .{ .head = bytes, .front = 0, .back = bytes.len, .name = name };
    }

    pub inline fn frontAllocMany(self: *@This(), comptime T: type, nmemb: usize) AllocError![]T {
        const pad = (~self.front +% 1) & (@alignOf(T) - 1);
        const aligned_off = self.front + pad;
        const avail = self.back -| aligned_off;

        if (TRACE_ALLOCATIONS)
            printAlloc(self, "FRONT", T, nmemb, pad);

        if (nmemb > avail / @sizeOf(T)) {
            @branchHint(.unlikely);
            return error.NoSpaceLeft;
        }
        const alloc_size = @sizeOf(T) * nmemb;

        self.front = aligned_off + alloc_size;

        const allocation = self.head[aligned_off..][0..alloc_size];
        if (builtin.mode == .Debug)
            @memset(allocation, 0xaa);

        return @alignCast(mem.bytesAsSlice(T, allocation));
    }

    pub inline fn frontAlloc(self: *@This(), comptime T: type) AllocError!*T {
        return @ptrCast(try self.frontAllocMany(T, 1));
    }

    pub inline fn backAllocMany(self: *@This(), comptime T: type, nmemb: usize) ![]T {
        const pad = self.back & (@alignOf(T) - 1);
        const aligned_off = self.back - pad;
        const avail = aligned_off -| self.front;

        if (TRACE_ALLOCATIONS)
            printAlloc(self, "BACK ", T, nmemb, pad);

        if (nmemb > avail / @sizeOf(T)) {
            @branchHint(.unlikely);
            return error.NoSpaceLeft;
        }
        const alloc_size = @sizeOf(T) * nmemb;

        self.back = aligned_off - alloc_size;

        const allocation = self.head[self.back..][0..alloc_size];
        if (builtin.mode == .Debug)
            @memset(allocation, 0xaa);

        return @alignCast(mem.bytesAsSlice(T, allocation));
    }

    pub inline fn backAlloc(self: *@This(), comptime T: type) AllocError!*T {
        return @ptrCast(try self.backAllocMany(T, 1));
    }

    pub inline fn frontWriteStr(self: *@This(), str: []const u8) AllocError![]const u8 {
        const retptr = try self.frontAllocMany(u8, str.len);
        @memcpy(retptr, str);
        return retptr;
    }

    pub inline fn frontWriteStrZ(self: *@This(), str: []const u8) AllocError![:0]const u8 {
        const retptr = try self.frontAllocMany(u8, str.len + 1);
        return memcpyZ(retptr, str) orelse unreachable;
    }

    pub inline fn frontPushVec(self: *@This(), vec: anytype) !*meta.Child(@TypeOf(vec.*)) {
        const T = meta.Child(@TypeOf(vec.*));
        var retptr = try self.frontAllocMany(T, 1);
        if (vec.len == 0) {
            vec.* = retptr;
        } else {
            vec.len += 1;
        }
        return &retptr[0];
    }

    pub inline fn backPushVec(self: *@This(), vec: anytype) !*meta.Child(@TypeOf(vec.*)) {
        const T = meta.Child(@TypeOf(vec.*));
        var retptr = try self.backAllocMany(T, 1);
        if (vec.len > 0) {
            retptr.len = vec.len + 1;
            mem.copyForwards(T, retptr, vec.*);
        }
        vec.* = retptr;
        return &retptr[retptr.len - 1];
    }

    pub inline fn save(self: @This(), comptime T: type, where: SavePoint.Where) SavePoint {
        return .{
            .where = where,
            .off = switch (where) {
                .front => mem.alignForward(usize, self.front, @alignOf(T)),
                .back => mem.alignBackward(usize, self.back, @alignOf(T)),
            },
        };
    }

    pub inline fn restore(self: *@This(), sp: SavePoint) void {
        switch (sp.where) {
            .front => self.front = sp.off,
            .back => self.back = sp.off,
        }
    }

    pub inline fn slice(self: @This(), comptime T: type, beg: SavePoint, len: usize) []T {
        return mem.bytesAsSlice(T, self.head[beg.off..][0 .. @sizeOf(T) * len]);
    }

    pub inline fn spaceLeft(self: @This(), comptime T: type) usize {
        const f = self.save(T, .front);
        const b = self.save(T, .back);
        if (f.off > b.off) return 0;
        return b.off - f.off;
    }

    pub inline fn spaceUsed(self: @This()) struct { usize, usize } {
        return .{ self.front, self.head.len - self.back };
    }
};

pub fn MemSlice(T: type) type {
    return struct {
        off: u16,
        len: u16,

        pub const zero: MemSlice(T) = .{ .off = 0, .len = 0 };

        pub fn get(self: @This(), base: [*]const u8) []const T {
            const size = @sizeOf(T) * self.len;
            return @alignCast(mem.bytesAsSlice(T, base[self.off..][0..size]));
        }

        pub inline fn writeBytes(
            self: @This(),
            writer: *uio.Writer,
            base: [*]const u8,
        ) void {
            // Make sure to compute the bounds check before the `dst` pointer
            // to reuse the `writer.end` that is already in the register for
            // the `dst` pointer calculation (`writer.buffer` + `writer.end`).
            const n = @min(self.len, writer.unusedCapacityLen());
            // Avoid an additional load through the writer pointer on every
            // iteration. Same as adding `noalias` to the writer parameter, but
            // plays well with forced inlining into callers without `noalias`
            // added therein. It leads to more register spills though as,
            // no wonder, the optimizer prioritizes loops over prologues.
            const dst = writer.buffer[writer.end..];
            // `off` should be upcast to at least u32 to avoid a zero extending
            // load during addressing. Alternatively, we can set up a pointer
            // with proper offset applied before entering the loop.
            const src = base[self.off..];
            for (0..n) |i| {
                dst[i] = src[i];
            }
            writer.end += n;
        }
    };
}
