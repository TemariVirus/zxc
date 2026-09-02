const std = @import("std");
const log = std.log.default;
const Io = std.Io;
const Dir = Io.Dir;

const files = @import("files.zig");

const HASH_LEN = 16;

/// Returns the hash of the given path, in hex.
fn getPathHash(path: []const u8) [HASH_LEN * 2]u8 {
    const H = std.crypto.hash.Blake3;
    comptime std.debug.assert(H.digest_length >= HASH_LEN);
    var hash: [HASH_LEN]u8 = undefined;
    H.hash(path, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn openStoreDir(io: Io, base_dir: Dir, options: Dir.OpenOptions) Dir.CreateDirPathOpenError!Dir {
    return base_dir.createDirPathOpen(io, "pv", .{ .open_options = options });
}

/// Changes the seek position of the file.
fn readEntryVersion(allocator: std.mem.Allocator, io: Io, file: Io.File) ![]u8 {
    var read_buf: [files.MAX_VERSION_LEN + 1]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.seekTo(0);
    const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.EndOfStream, error.StreamTooLong => return error.UnexpectedFormat,
    };
    return try allocator.dupe(u8, line[0 .. line.len - 1]);
}

/// Changes the seek position of the file.
fn readEntryPath(allocator: std.mem.Allocator, io: Io, file: Io.File) ![]const u8 {
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.seekTo(0);
    // Discard version
    _ = reader.interface.discardDelimiterInclusive('\n') catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.EndOfStream => return error.UnexpectedFormat,
    };

    const path = reader.interface.allocRemaining(allocator, .limited(Dir.max_path_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.UnexpectedFormat,
        else => |e| return e,
    };
    errdefer allocator.free(path);
    if (path.len == 0 or !Dir.path.isAbsolute(path)) {
        return error.UnexpectedFormat;
    }
    return path;
}

/// Returns the previously selected version for the given path,
/// or `null` if there is no previous selection.
pub fn getVersion(
    allocator: std.mem.Allocator,
    io: Io,
    base_dir: Dir,
    path: []const u8,
) !?[]const u8 {
    const store = openStoreDir(io, base_dir, .{}) catch |err| switch (err) {
        error.FileNotFound,
        error.NameTooLong,
        error.BadPathName,
        => return null,
        else => |e| return e,
    };
    defer store.close(io);
    const file = store.openFile(io, &getPathHash(path), .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound,
        error.NameTooLong,
        error.BadPathName,
        => return null,
        else => |e| return e,
    };
    defer file.close(io);
    return try readEntryVersion(allocator, io, file);
}

/// Adds an entry to associate `path` with `version` in the store.
pub fn addEntry(
    io: Io,
    base_dir: Dir,
    path: []const u8,
    version: []const u8,
) !void {
    if (!Dir.path.isAbsolute(path)) return error.NotAbsolutePath;

    const store = try openStoreDir(io, base_dir, .{});
    defer store.close(io);
    var entry = try store.createFileAtomic(io, &getPathHash(path), .{ .replace = true });
    defer entry.deinit(io);
    var buf: [4096]u8 = undefined;
    var writer = entry.file.writer(io, &buf);
    writer.interface.print("{s}\n{s}", .{ version, path }) catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
    };
    writer.end() catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
        else => |e| return e,
    };
    try entry.replace(io);
}

/// Calls `addEntry` with the current working directory as the `path` parameter.
pub fn addEntryCwd(
    io: Io,
    base_dir: Dir,
    version: []const u8,
) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try std.process.currentPath(io, &path_buf)];
    try addEntry(io, base_dir, path, version);
}

fn deleteIfInvalidEntry(io: Io, store: Dir, entry: Dir.Entry) !void {
    if (entry.kind != .file) {
        try store.deleteTree(io, entry.name);
        return;
    }

    const invalidated = blk: {
        const file = try store.openFile(io, entry.name, .{});
        defer file.close(io);
        var path_buf: [Dir.max_path_bytes]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
        const path = readEntryPath(fba.allocator(), io, file) catch |err| switch (err) {
            error.UnexpectedFormat => break :blk true,
            else => |e| return e,
        };
        if (!std.mem.eql(u8, entry.name, &getPathHash(path))) {
            break :blk true;
        }
        Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.BadPathName => break :blk true,
            else => |e| return e,
        };
        break :blk false;
    };
    if (invalidated) {
        try store.deleteFile(io, entry.name);
    }
}

/// Tries to delete entries whose paths no longer exist, and malformed files.
pub fn cleanUpEntries(io: Io, base_dir: Dir) Io.Cancelable!void {
    const store = openStoreDir(io, base_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return,
    };
    defer store.close(io);

    var iter = store.iterate();
    while (iter.next(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return,
    }) |entry| {
        deleteIfInvalidEntry(io, store, entry) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
    }
}
