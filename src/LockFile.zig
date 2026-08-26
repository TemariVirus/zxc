//! File-based lock for coordinating multiple processes.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

const LockFile = @This();

dir: Dir,
file: Io.File,
name: []const u8,

pub fn isValidKey(key: []const u8) bool {
    return !std.mem.startsWith(u8, key, "lock.") and
        Dir.path.basename(key).len == key.len;
}

fn getNameFromKey(allocator: Allocator, key: []const u8) Allocator.Error![]const u8 {
    std.debug.assert(isValidKey(key));
    const path = try allocator.alloc(u8, 5 + key.len);
    @memcpy(path[0..5], "lock.");
    @memcpy(path[5..], key);
    return path;
}

fn getKeyFromName(name: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, name, "lock.")) name[5..] else null;
}

/// Blocks until the lock is available.
pub fn lock(allocator: Allocator, io: Io, dir: Dir, key: []const u8) !LockFile {
    const name = try getNameFromKey(allocator, key);
    errdefer allocator.free(name);
    const file = dir.createFile(io, name, .{
        .exclusive = false,
        .lock = .exclusive,
        .lock_nonblocking = false,
    }) catch |err| switch (err) {
        error.PathAlreadyExists, error.WouldBlock => unreachable,
        else => |e| return e,
    };
    return .{ .dir = dir, .file = file, .name = name };
}

/// If the lock is available, acquires the lock.
/// Otherwise, returns `error.WouldBlock`.
pub fn tryLock(allocator: Allocator, io: Io, dir: Dir, key: []const u8) !LockFile {
    const name = try getNameFromKey(allocator, key);
    errdefer allocator.free(name);
    const file = dir.createFile(io, name, .{
        .exclusive = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => unreachable,
        else => |e| return e,
    };
    return .{ .dir = dir, .file = file, .name = name };
}

pub fn unlock(self: LockFile, allocator: Allocator, io: Io) void {
    switch (builtin.os.tag) {
        .windows => {
            // Windows cannot delete the file while there is an open handle
            self.file.close(io);
            self.dir.deleteFile(io, self.name) catch {};
        },
        else => {
            self.dir.deleteFile(io, self.name) catch {};
            self.file.close(io);
        },
    }
    allocator.free(self.name);
}

/// Opens and returns the directory associated with this lock.
pub fn getLockedDir(self: LockFile, io: Io, options: Dir.CreateDirPathOpenOptions) !Dir {
    const key = getKeyFromName(self.name).?;
    return try self.dir.createDirPathOpen(io, key, options);
}

/// Cleans up unused locks and their directories from a parent directory.
/// `dir` must be opened with `.iterate = true`.
pub fn cleanUpUnlocked(io: Io, dir: Dir) void {
    var fba_buf: [Dir.max_name_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const allocator = fba.allocator();

    var iter = dir.iterate();
    while (iter.next(io) catch return) |entry| {
        const key = getKeyFromName(entry.name) orelse entry.name;
        const lockf = LockFile.tryLock(allocator, io, dir, key) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
        defer lockf.unlock(allocator, io);
        _ = switch (entry.kind) {
            .directory => dir.deleteTree(io, entry.name),
            else => dir.deleteFile(io, entry.name),
        } catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
    }
}
