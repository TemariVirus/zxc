//! File-based lock for coordinating multiple processes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

const LockFile = @This();

dir: Io.Dir,
file: Io.File,
path: []const u8,

fn getPathFromKey(allocator: Allocator, key: []const u8) ![]const u8 {
    const path = try allocator.alloc(u8, key.len + 5);
    @memcpy(path[0..key.len], key);
    @memcpy(path[key.len..], ".lock");
    return path;
}

/// Blocks until the lock is available.
pub fn lock(allocator: Allocator, io: Io, dir: Io.Dir, key: []const u8) !LockFile {
    const path = try getPathFromKey(allocator, key);
    errdefer allocator.free(path);
    const file = dir.createFile(io, path, .{
        .truncate = false,
        .exclusive = false,
        .lock = .exclusive,
        .lock_nonblocking = false,
    }) catch |err| switch (err) {
        error.PathAlreadyExists, error.WouldBlock => unreachable,
        else => |e| return e,
    };
    return .{ .dir = dir, .file = file, .path = path };
}

/// If the lock is available, acquires the lock.
/// Otherwise, returns `error.WouldBlock`.
pub fn tryLock(allocator: Allocator, io: Io, dir: Io.Dir, key: []const u8) !LockFile {
    const path = try getPathFromKey(allocator, key);
    errdefer allocator.free(path);
    const file = dir.createFile(io, path, .{
        .truncate = false,
        .exclusive = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => unreachable,
        else => |e| return e,
    };
    return .{ .dir = dir, .file = file, .path = path };
}

pub fn unlock(self: LockFile, allocator: Allocator, io: Io) void {
    switch (builtin.os.tag) {
        .windows => {
            // Windows cannot delete the file while there is an open handle
            self.file.close(io);
            self.dir.deleteFile(io, self.path) catch {};
        },
        else => {
            self.dir.deleteFile(io, self.path) catch {};
            self.file.close(io);
        },
    }
    allocator.free(self.path);
}
