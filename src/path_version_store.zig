// TODO: remove invalid entries on slower invocations of zxc
const std = @import("std");
const log = std.log.default;
const Io = std.Io;
const Dir = Io.Dir;

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
    return store.readFileAlloc(io, &getPathHash(path), allocator, .limited(64)) catch |err| switch (err) {
        error.FileNotFound,
        error.NameTooLong,
        error.BadPathName,
        => null,
        else => |e| e,
    };
}

/// Adds an entry to associate `path` with `version` in the store.
pub fn addEntry(
    io: Io,
    base_dir: Dir,
    path: []const u8,
    version: []const u8,
) !void {
    const store = try openStoreDir(io, base_dir, .{});
    defer store.close(io);

    var entry = try store.createFileAtomic(io, &getPathHash(path), .{ .replace = true });
    defer entry.deinit(io);
    try entry.file.writeStreamingAll(io, version);
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
