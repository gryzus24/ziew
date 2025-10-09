const std = @import("std");

const ext = @import("ext.zig");
const umem = @import("mem.zig");
const ustr = @import("str.zig");

const linux = std.os.linux;
const posix = std.posix;

pub inline fn sys_write(fd: linux.fd_t, str: []const u8) isize {
    return @bitCast(linux.write(fd, str.ptr, str.len));
}

pub inline fn sys_writev(fd: linux.fd_t, vs: anytype) isize {
    const len = @typeInfo(@TypeOf(vs)).@"struct".fields.len;
    var iovs: [len]posix.iovec_const = undefined;
    inline for (vs, 0..) |s, i| iovs[i] = .{ .base = s.ptr, .len = s.len };
    return @bitCast(linux.writev(fd, &iovs, iovs.len));
}

pub inline fn sys_pread(fd: linux.fd_t, buf: []u8, off: linux.off_t) isize {
    return @bitCast(linux.pread(fd, buf.ptr, buf.len, off));
}

pub inline fn pread(fd: linux.fd_t, buf: []u8, off: linux.off_t) error{ReadError}!usize {
    while (true) {
        const ret = sys_pread(fd, buf, off);
        if (ret >= 0) {
            @branchHint(.likely);
            return @intCast(ret);
        }
        if (ret != -ext.c.EINTR) return error.ReadError;
    }
}

pub inline fn open0(path: [*:0]const u8) posix.OpenError!linux.fd_t {
    return posix.openZ(path, .{}, undefined);
}

pub inline fn openCWA(path: [*:0]const u8, mode: linux.mode_t) posix.OpenError!linux.fd_t {
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    };
    return posix.openZ(path, flags, mode);
}

pub inline fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

pub inline fn writeStr(writer: *Writer, str: []const u8) void {
    const n = @min(str.len, writer.unusedCapacityLen());
    const dst = writer.buffer[writer.end..];
    for (0..n) |i| dst[i] = str[i];
    writer.end += n;
}

// Simpler, vtable-less Writer shim.
pub const Writer = struct {
    buffer: []u8,
    end: usize,

    pub fn fixed(buffer: []u8) @This() {
        return .{ .buffer = buffer, .end = 0 };
    }

    pub fn buffered(self: *@This()) []u8 {
        return self.buffer[0..self.end];
    }

    pub fn unusedCapacityLen(self: *const @This()) usize {
        return self.buffer.len - self.end;
    }
};

pub const Buffer = struct {
    read: ReadFunc,
    rebase: ?RebaseFunc,
    buf: []u8,
    end: usize,

    const ReadFunc = *const fn (*Buffer, n: usize) error{ReadError}!usize;
    const RebaseFunc = *const fn (*Buffer, cut: usize) usize;

    pub fn buffered(self: *Buffer) []u8 {
        return self.buf[0..self.end];
    }

    pub fn fixed(buf: []const u8) Buffer {
        return .{
            .read = fixedRead,
            .rebase = null,
            .buf = @constCast(buf),
            .end = 0,
        };
    }

    fn fixedRead(self: *Buffer, n: usize) error{ReadError}!usize {
        const max = @min(self.buf.len - self.end, n);
        self.end += max;
        return max;
    }
};

pub const BufferedFile = struct {
    fd: linux.fd_t,
    buffer: Buffer,

    pub fn init(fd: linux.fd_t, buf: []u8) @This() {
        return .{
            .fd = fd,
            .buffer = .{
                .read = fileRead,
                .rebase = fileRebase,
                .buf = buf,
                .end = 0,
            },
        };
    }

    fn fileRead(b: *Buffer, n: usize) error{ReadError}!usize {
        const self: *BufferedFile = @fieldParentPtr("buffer", b);
        const max = @min(b.buf.len - b.end, n);
        const nr_read = posix.read(self.fd, b.buf[b.end..][0..max]) catch
            return error.ReadError;
        b.end += nr_read;
        return nr_read;
    }

    fn fileRebase(b: *Buffer, cut: usize) usize {
        if (cut != 0) {
            const after = b.buf[cut..b.end];
            const end = after.len;
            @memmove(b.buf[0..end], after);
            b.end = end;
        }
        return b.buf.len - b.end;
    }
};

pub const LineReader = struct {
    nit: ustr.IndexIterator(u8, '\n'),
    buffer: *Buffer,
    pos: usize,
    eof: bool,

    pub const Termination = error{
        EOF,
        NoNewline,
        ReadError,
    };

    pub fn init(b: *Buffer) @This() {
        const eof = b.read(b, b.buf.len) catch |e| switch (e) {
            error.ReadError => 0,
        } == 0;
        return .{
            .nit = .init(b.buffered()),
            .buffer = b,
            .pos = 0,
            .eof = eof,
        };
    }

    pub fn readLine(self: *@This()) Termination![]const u8 {
        if (self.eof) return error.EOF;
        const b = self.buffer;
        retry: while (true) {
            // - `pos` tends toward `end`.
            // - `end` tends toward `buf.len`, and tapers off at the end...
            if (self.nit.next()) |nl| {
                const line = b.buf[self.pos..nl];
                self.pos = nl + 1;
                return line;
            }
            if (b.end == b.buf.len) {
                // There is nothing to rebase... Line's too mighty for us.
                if (self.pos == 0) return error.NoNewline;
                // Unfortunately we can't catch the:
                // `buf.len` == data available, `pos == 0`, and no newline
                // at buffer's end, not that it matters...
                if (b.rebase) |rebase| {
                    const nr_free = rebase(b, self.pos);
                    std.debug.assert(nr_free > 0);
                    self.pos = 0;

                    if (try b.read(b, nr_free) > 0) {
                        @branchHint(.likely);
                        self.nit = .init(b.buffered());
                        continue :retry;
                    }
                    // We've got perfect buffer size and there
                    // is no newline at buffer's end.
                }
            } else if (self.pos == b.end) {
                // We got it all cleanly.
                self.eof = true;
                return error.EOF;
            }
            // Someone forgot to put a newline at buffer's end...
            self.eof = true;
            return b.buf[self.pos..b.end];
        }
    }
};
