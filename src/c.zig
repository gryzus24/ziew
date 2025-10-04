// zig fmt: off
pub const c = @cImport({
    @cInclude("errno.h");      // errno constants
    @cInclude("sys/statfs.h"); // statfs()
    @cInclude("time.h");       // strftime() etc.
});
// zig fmt: on
