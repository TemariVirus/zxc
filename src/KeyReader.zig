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
/// Indicates that there is nothing to read from `stdin`.
/// This byte value is not used by escape sequences or UTF-8.
const NO_INPUT: u8 = 255;

stdin: std.Io.File,
termios: posix.termios,

pub fn init() !KeyReader {
    const stdin = std.Io.File.stdin();
    const termios = try posix.tcgetattr(stdin.handle);

    var new_termios = termios;
    new_termios.cflag.CSIZE = .CS8; // 8 bits per character
    new_termios.lflag.ICANON = false; // Disable line buffering
    new_termios.lflag.ECHO = false; // Don't echo input
    new_termios.lflag.ISIG = false; // Disable ctrl+c and ctrl+z signals
    new_termios.cc[@intFromEnum(posix.V.MIN)] = 0; // Block until we can read a byte
    // TODO: this is not foolproof and will not work if the user presses keys fast enough
    // Timeout after 0.1s, to differentiate the escape key from escape sequences
    new_termios.cc[@intFromEnum(posix.V.TIME)] = 1;
    try posix.tcsetattr(stdin.handle, .FLUSH, new_termios);

    return KeyReader{
        .stdin = stdin,
        .termios = termios,
    };
}

/// Restores original terminal settings.
pub fn deinit(self: KeyReader) void {
    posix.tcsetattr(self.stdin.handle, .FLUSH, self.termios) catch {};
}

fn takeByte(self: KeyReader, io: std.Io) !u8 {
    var buf: [1]u8 = undefined;
    var reader = self.stdin.readerStreaming(io, &buf);
    return reader.interface.takeByte() catch |err| switch (err) {
        error.ReadFailed => reader.err.?,
        error.EndOfStream => NO_INPUT,
    };
}

/// Returns the next key pressed.
pub fn read(self: KeyReader, io: std.Io) !Key {
    // Guesswork based on me pressing a bunch of keys in Ghostty
    const State = enum {
        empty,
        esc,
        f1234,
        csi,
        discard_csi,
    };
    loop: switch (State.empty) {
        .empty => switch (try self.takeByte(io)) {
            0x03 => return .sigint,
            '\n' => return .enter,
            0x1b => continue :loop .esc,
            // This also means CSI apparently? I've never obsevered it myself though
            0x9b => continue :loop .csi,
            else => continue :loop .empty,
        },
        .esc => switch (try self.takeByte(io)) {
            'O' => continue :loop .f1234,
            '[' => continue :loop .csi,
            else => continue :loop .empty,
        },
        .f1234 => {
            // F1 => P, F2 => Q, F3 => R, F4 => S
            _ = try self.takeByte(io);
            continue :loop .empty;
        },
        .csi => switch (try self.takeByte(io)) {
            'A' => return .up,
            'B' => return .down,
            '@'...'A' - 1, 'C'...'~', NO_INPUT => continue :loop .empty,
            else => continue :loop .discard_csi,
        },
        .discard_csi => while (true) switch (try self.takeByte(io)) {
            '@'...'~', NO_INPUT => continue :loop .empty,
            else => continue,
        },
    }
}
