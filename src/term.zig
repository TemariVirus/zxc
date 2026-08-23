//!Interative terminal control. Mostly ANSI escape sequences.
const std = @import("std");

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
