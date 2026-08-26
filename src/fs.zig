const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

/// Joins the paths in `paths` with the existing path `buf[0..base_len]`.
/// Returns a slice into `buf`.
pub fn joinPathsInPlace(buf: []u8, base_len: usize, paths: []const []const u8) error{OutOfMemory}![]u8 {
    const isSep = Dir.path.isSep;
    const first_path = for (paths) |p| {
        if (p.len > 0) break p;
    } else return buf[0..base_len];
    const start = if (base_len == 0)
        0
    else
        base_len + 1 - @intFromBool(isSep(buf[base_len - 1])) - @intFromBool(isSep(first_path[0]));

    if (!isSep(buf[base_len - 1]) and !isSep(first_path[0])) {
        buf[start - 1] = Dir.path.sep;
    }
    var fba: std.heap.FixedBufferAllocator = .init(buf[start..]);
    const n = (try Dir.path.join(fba.allocator(), paths)).len;
    return buf[0 .. start + n];
}

/// Forces a rename by first deleting `new_sub_path`.
pub fn forceRename(
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
    io: Io,
) !void {
    try new_dir.deleteTree(io, new_sub_path);
    try Dir.rename(old_dir, old_sub_path, new_dir, new_sub_path, io);
}

/// Copies the tree at `old_sub_path` to `new_sub_path`, preserving file permissions.
/// This function is not atomic.
pub fn copyTree(
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
    kind: ?File.Kind,
    io: Io,
) !void {
    const file_kind = kind orelse
        (try old_dir.statFile(io, old_sub_path, .{})).kind;
    switch (file_kind) {
        .directory => {},
        else => return try old_dir.copyFile(old_sub_path, new_dir, new_sub_path, io, .{}),
    }

    const od = try old_dir.openDir(io, old_sub_path, .{ .iterate = true });
    defer od.close(io);
    const nd = try new_dir.createDirPathOpen(io, new_sub_path, .{});
    defer nd.close(io);
    var iter = od.iterate();
    while (try iter.next(io)) |entry| {
        try copyTree(od, entry.name, nd, entry.name, entry.kind, io);
    }
}

/// Reads and returns the contents of `file`.
/// Returns `error.WrongSize` if the size of `file` was not `size.
pub fn readAllExact(allocator: Allocator, io: Io, file: File, size: usize) ![]const u8 {
    var reader: File.Reader = .initSize(file, io, &.{}, size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    reader.interface.readSliceAll(content) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.EndOfStream => return error.WrongSize,
    };
    if (!reader.atEnd()) return error.WrongSize;
    return content;
}
