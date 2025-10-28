const builtin = @import("builtin");
const std = @import("std");
const uio = @import("io.zig");
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;

// == private =================================================================

fn printAlloc(reg: *Region, where: Region.Where, comptime T: type, nmemb: usize, pad: usize) void {
    const front, const back = reg.spaceUsed();
    const total_size = @sizeOf(T) * nmemb + pad;
    const str = if (where == .front) "FRONT" else "BACK ";

    var writer = fs.File.stderr().writer(&.{});
    const stderr = &writer.interface;

    stderr.print(
        "{s:<8} F={:<4} B={:<4} T={:<5} | ({s}) PAD={} N={:<4} SZ={:<4} TSZ={:<4} {}\n",
        .{ reg.name, front, back, front + back, str, pad, nmemb, @sizeOf(T), total_size, T },
    ) catch {};
}

fn bytesAsSliceOrganic(comptime T: type, bytes: anytype) []T {
    const w: [*]T = @ptrCast(@alignCast(bytes.ptr));
    return w[0..@divExact(bytes.len, @sizeOf(T))];
}

// Just duplicate this function for const,
// don't bother copying all pointer attributes.
fn bytesAsConstSliceOrganic(comptime T: type, bytes: anytype) []const T {
    const w: [*]const T = @ptrCast(@alignCast(bytes.ptr));
    return w[0..@divExact(bytes.len, @sizeOf(T))];
}

// == public ==================================================================

pub fn memcpyZ(dst: []u8, src: []const u8) ?[:0]const u8 {
    if (src.len >= dst.len) return null;
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return dst[0..src.len :0];
}

pub const TRACE_ALLOCATIONS = @import("config").mem_trace_allocations;

pub const OOM_CHECK = !@import("config").mem_no_oom_check;

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

    pub const Error = error{NoSpaceLeft};

    pub const Where = enum(u8) { front, back };

    pub const SavePoint = struct {
        where: Where,
        off: usize,
    };

    pub fn init(bytes: []align(16) u8, name: []const u8) Region {
        return .{ .head = bytes, .front = 0, .back = bytes.len, .name = name };
    }

    pub inline fn allocMany(self: *@This(), comptime T: type, nmemb: usize, comptime where: Where) Error![]T {
        if (@sizeOf(T) == 0)
            @compileError("Tried to allocate a zero-sized type");

        const alloc_size = @sizeOf(T) * nmemb;
        const allocation = switch (where) {
            .front => alloc: {
                const pad = (~self.front +% 1) & (@alignOf(T) - 1);
                const aligned_off = self.front + pad;
                const avail = self.back -| aligned_off;

                if (TRACE_ALLOCATIONS)
                    printAlloc(self, where, T, nmemb, pad);

                if (OOM_CHECK and nmemb > avail / @sizeOf(T)) {
                    @branchHint(.unlikely);
                    return error.NoSpaceLeft;
                }
                self.front = aligned_off + alloc_size;
                break :alloc self.head[aligned_off..][0..alloc_size];
            },
            .back => alloc: {
                const pad = self.back & (@alignOf(T) - 1);
                const aligned_off = self.back - pad;
                const avail = aligned_off -| self.front;

                if (TRACE_ALLOCATIONS)
                    printAlloc(self, where, T, nmemb, pad);

                if (OOM_CHECK and nmemb > avail / @sizeOf(T)) {
                    @branchHint(.unlikely);
                    return error.NoSpaceLeft;
                }
                self.back = aligned_off - alloc_size;
                break :alloc self.head[self.back..][0..alloc_size];
            },
        };
        if (builtin.mode == .Debug)
            @memset(allocation, 0xaa);

        // `mem.bytesAsSlice` does some paranoia checks before the cast
        // which take up a whole register just to insert pattern poison
        // 0xaa and cmov that into the slice pointer if it turns out it
        // has a length of zero. We have good bytes! Valid bytes! Their
        // provenance is more important for debugging than some poison!
        return bytesAsSliceOrganic(T, allocation);
    }

    pub inline fn alloc(self: *@This(), comptime T: type, where: Where) Error!*T {
        return @ptrCast(try self.allocMany(T, 1, where));
    }

    pub inline fn writeStr(self: *@This(), str: []const u8, comptime where: Where) Error![]const u8 {
        const retptr = try self.allocMany(u8, str.len, where);
        @memcpy(retptr, str);
        return retptr;
    }

    pub inline fn writeStrZ(self: *@This(), str: []const u8, comptime where: Where) Error![:0]const u8 {
        const retptr = try self.allocMany(u8, str.len + 1, where);
        return memcpyZ(retptr, str) orelse unreachable;
    }

    pub inline fn pushVec(self: *@This(), vec: anytype, comptime where: Where) Error!*meta.Child(@TypeOf(vec.*)) {
        const T = meta.Child(@TypeOf(vec.*));
        return switch (where) {
            .front => blk: {
                var retptr = try self.allocMany(T, 1, .front);
                if (vec.len == 0) {
                    vec.* = retptr;
                } else {
                    vec.len += 1;
                }
                break :blk &retptr[0];
            },
            .back => blk: {
                var retptr = try self.allocMany(T, 1, .back);
                if (vec.len > 0) {
                    retptr.len = vec.len + 1;
                    mem.copyForwards(T, retptr, vec.*);
                }
                vec.* = retptr;
                break :blk &retptr[retptr.len - 1];
            },
        };
    }

    pub inline fn save(self: @This(), comptime T: type, comptime where: Where) SavePoint {
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
        const bytes = self.head[beg.off..][0 .. @sizeOf(T) * len];
        return bytesAsSliceOrganic(T, bytes);
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
            const bytes = base[self.off..][0 .. @sizeOf(T) * self.len];
            return bytesAsConstSliceOrganic(T, bytes);
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
