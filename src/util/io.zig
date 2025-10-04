const std = @import("std");
const su = @import("str.zig");
const io = std.io;
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

pub inline fn writeStr(writer: *io.Writer, str: []const u8) void {
    const n = @min(str.len, writer.unusedCapacityLen());
    const dst = writer.buffer[writer.end..];
    for (0..n) |i| dst[i] = str[i];
    writer.end += n;
}

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

pub const FileBuffer = struct {
    fd: std.os.linux.fd_t,
    buffer: Buffer,

    pub fn init(fd: std.os.linux.fd_t, buf: []u8) @This() {
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
        const self: *FileBuffer = @fieldParentPtr("buffer", b);
        const max = @min(b.buf.len - b.end, n);
        const nr_read = posix.read(self.fd, b.buf[b.end..][0..max]) catch {
            return error.ReadError;
        };
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
    nit: su.IndexIterator(u8, '\n'),
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
        // `pos` tends toward `end` - `end` tends toward zero.
        const b = self.buffer;
        while (true) {
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
                // at buffer's end.
                if (b.rebase) |rebase| {
                    const nr_free = rebase(b, self.pos);
                    if (try b.read(b, nr_free) == 0) {
                        @branchHint(.unlikely);
                        // We've got perfect buffer size and there
                        // is no delimiter at buffer's end.
                        self.eof = true;
                        break;
                    } else {
                        self.pos = 0;
                        self.nit = .init(b.buffered());
                    }
                }
            } else {
                // We got it all.
                if (self.pos == b.end) return error.EOF;
                // Someone forgot to put a newline at buffer's end...
                self.eof = true;
                break;
            }
        }
        return b.buf[self.pos..b.end];
    }
};
