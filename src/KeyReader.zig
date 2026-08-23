//! TODO: windows support?

const std = @import("std");
const posix = std.posix;

pub const Key = enum {
    enter,
    up,
    down,
    sigint,
};

const KeyReader = @This();

stdin_fd: std.Io.File.Handle,
termios: posix.termios,

pub fn init() !KeyReader {
    const stdin_fd = std.Io.File.stdin().handle;
    const termios = try posix.tcgetattr(stdin_fd);

    var new_termios = termios;
    new_termios.lflag.ICANON = false; // Disable line buffering
    new_termios.lflag.ECHO = false; // Don't echo input
    new_termios.lflag.ISIG = false; // Disable ctrl+c and ctrl+z signals
    new_termios.cc[@intFromEnum(posix.V.MIN)] = 1; // Block until we can read a byte
    try posix.tcsetattr(stdin_fd, .FLUSH, new_termios);

    return KeyReader{
        .stdin_fd = stdin_fd,
        .termios = termios,
    };
}

/// Restores original terminal settings.
pub fn deinit(self: KeyReader) void {
    posix.tcsetattr(self.stdin_fd, .FLUSH, self.termios) catch {};
}

fn takeByte(self: KeyReader) !u8 {
    var buf: [1]u8 = undefined;
    while (try posix.read(self.stdin_fd, &buf) < 1) {}
    return buf[0];
}

/// Returns the next key pressed.
pub fn read(self: KeyReader) !Key {
    const State = enum {
        empty, // ""
        esc, // "\x1b"
        csi, // "\x1b["
    };
    loop: switch (State.empty) {
        .empty => switch (try self.takeByte()) {
            0x03 => return .sigint,
            0x1b => continue :loop .esc,
            '\n' => return .enter,
            else => continue :loop .empty,
        },
        .esc => switch (try self.takeByte()) {
            '[' => continue :loop .csi,
            else => continue :loop .empty,
        },
        .csi => switch (try self.takeByte()) {
            0x1b => continue :loop .esc,
            'A' => return .up,
            'B' => return .down,
            else => continue :loop .empty,
        },
    }
}
