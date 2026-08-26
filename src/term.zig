//!Interactive terminal control. Mostly ANSI escape sequences.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Writer = std.Io.Writer;

const http = @import("http.zig");

const CSI = "\x1b[";

pub const DownloadProgress = struct {
    io: std.Io,
    start_t: std.Io.Timestamp,
    downloaded: u64 = 0,
    total: ?u64,

    pub fn start(io: std.Io, total: ?u64) DownloadProgress {
        return DownloadProgress{
            .io = io,
            .start_t = .now(io, .real),
            .total = total,
        };
    }

    pub fn writeProgress(self: DownloadProgress, stdout: *Writer, last: bool) !void {
        const dur = self.start_t.untilNow(self.io, .real);
        const bytes_per_s: u64 = @intCast(std.time.ns_per_s * @as(u96, self.downloaded) / @max(1, dur.nanoseconds));
        try clearLine(stdout);
        try stdout.print(
            "Downloaded {B: >8.2}",
            .{self.downloaded},
        );
        if (self.total) |total| {
            try stdout.print(
                " of {B:.2}",
                .{total},
            );
        }
        try stdout.print(
            " ({B:.2}/s)",
            .{bytes_per_s},
        );
        if (last) try stdout.writeByte('\n');
        try stdout.flush();
    }

    pub fn streamResultAndWriteProgress(
        result: *http.FetchResult,
        out_writer: *Writer,
        stdout: *Writer,
        total: ?u64,
    ) !void {
        const io = result.request.client.io;
        var progress: DownloadProgress = .start(io, total);
        while (true) {
            progress.downloaded += result.reader.stream(out_writer, .unlimited) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return result.getReadErr(),
                error.WriteFailed => |e| return e,
            };
            progress.writeProgress(stdout, false) catch {};
            if (total) |t| if (progress.downloaded > t) return error.WrongSize;
        }
        progress.writeProgress(stdout, true) catch {};
        if (total) |t| if (progress.downloaded != t) return error.WrongSize;
        try out_writer.flush();
    }
};

pub fn previousLine(stdout: *Writer, n: u32) !void {
    try stdout.print(CSI ++ "{d}F", .{n});
}

pub fn erase(stdout: *Writer, mode: enum(u8) {
    after_cursor = 0,
    before_cursor = 1,
    screen = 2,
    all = 3,
}) !void {
    try stdout.print(CSI ++ "{d}J", .{@intFromEnum(mode)});
}

/// Resets cursor position to the start of the current line.
pub fn clearLine(stdout: *Writer) !void {
    try stdout.writeAll("\r" ++ CSI ++ "K");
}

pub fn setCursorVisibility(writer: *Writer, show: bool) !void {
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
