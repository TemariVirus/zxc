const std = @import("std");
const Scanner = std.json.Scanner;

/// Skip to the end of the current object.
/// The next token must be `.string` or `.object_end`.
pub fn skipToEndOfObject(scanner: *Scanner) !void {
    while (true) {
        switch (try scanner.next()) {
            .string => try scanner.skipValue(),
            .object_end => break,
            else => unreachable,
        }
    }
}

/// Skip the the value corresponding to the key in the current object.
/// If the key is not found, skip to the end of the object instead and returns `error.NoMoreKeys`.
/// The next token must be `.string` or `.object_end`.
pub fn skipToKey(scanner: *Scanner, key: []const u8) !void {
    while (true) {
        switch (try scanner.next()) {
            .string => |actual_key| if (std.mem.eql(u8, key, actual_key)) return,
            .object_end => return error.NoMoreKeys,
            else => unreachable,
        }
        try scanner.skipValue();
    }
}

/// Skip the the value corresponding to the key in the next object.
/// If the key is not found, skip to the end of the object instead and returns `error.NoMoreKeys`.
/// The next token must be `.object_begin`.
pub fn skipToObjectKey(scanner: *Scanner, key: []const u8) !void {
    switch (try scanner.next()) {
        .object_begin => {},
        else => return error.NotAnObject,
    }
    return skipToKey(scanner, key);
}

/// If the next key in the current object is `key`, parses and returns the corresponding value.
/// Otherwise, skips the value and returns `null`.
/// The next token must be `.string` or `.object_end`.
pub fn parseValueIfEqlKey(T: type, scanner: *Scanner, key: []const u8) !?T {
    switch (try scanner.next()) {
        .string => |actual_key| {
            if (std.mem.eql(u8, key, actual_key)) {
                return try parseNext(T, scanner);
            }
            try scanner.skipValue();
            return null;
        },
        .object_end => return error.NoMoreKeys,
        else => unreachable,
    }
}

/// Consume and parse the next token into a value of type `T`.
pub fn parseNext(T: type, scanner: *Scanner) !T {
    switch (@typeInfo(T)) {
        .int => switch (try scanner.next()) {
            .string, .number => |str| return std.fmt.parseInt(T, str, 10),
            else => return error.UnexpectedToken,
        },
        .pointer => |info| {
            if (info.size != .slice or info.child != u8) {
                @compileError("Unsupported type");
            }
            switch (try scanner.next()) {
                .string => |str| return str,
                else => return error.UnexpectedToken,
            }
        },
        else => @compileError("Unsupported type"),
    }
}
