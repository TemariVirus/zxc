//!Interactive terminal control. Mostly ANSI escape sequences.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const CSI = "\x1b[";

pub fn previousLine(stdout: *std.Io.Writer, n: u32) !void {
    try stdout.print(CSI ++ "{d}F", .{n});
}

pub fn erase(stdout: *std.Io.Writer, mode: enum(u8) {
    after_cursor = 0,
    before_cursor = 1,
    screen = 2,
    all = 3,
}) !void {
    try stdout.print(CSI ++ "{d}J", .{@intFromEnum(mode)});
}

pub fn setCursorVisibility(writer: *std.Io.Writer, show: bool) !void {
    if (show) {
        try writer.writeAll(CSI ++ "?25h");
    } else {
        try writer.writeAll(CSI ++ "?25l");
    }
}

// Not linking musl libc saves us ~100KB in binary size
pub fn isatty(fd: std.posix.fd_t) error{ FileNotOpen, Unexpected }!bool {
    const E = posix.E;

    var tmp: posix.winsize = undefined;
    const rc = linux.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&tmp));
    switch (posix.errno(rc)) {
        E.SUCCESS => return true,
        E.NOTTY => return false,
        E.BADF => return error.FileNotOpen,
        else => return error.Unexpected,
    }
}
