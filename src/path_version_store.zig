// TODO: compare performance with content-addressed file per path
// TODO: remove invalid entries on slower invocations of zxc
const std = @import("std");
const log = std.log.default;
const Io = std.Io;
const Dir = Io.Dir;

const STORE_FILENAME = "path_verions";

const Iterator = struct {
    reader: *Io.Reader,
    entry_buf: []u8,

    /// Stores the previously selected Zig version for a path.
    pub const Entry = struct {
        /// An absolute path.
        path: []const u8,
        /// A semantic version.
        version: []const u8,
        /// The line in the file containing the encoded `path` and `version`.
        /// Does not include the '\n' character.
        raw_line: []const u8,
    };

    pub fn init(reader: *Io.Reader, allocator: std.mem.Allocator) !Iterator {
        const MAX_PATH_LEN = Dir.max_path_bytes * 2;
        const buf = try allocator.alloc(u8, @min(reader.buffer.len, MAX_PATH_LEN));
        return .{
            .reader = reader,
            .entry_buf = buf,
        };
    }

    pub fn deinit(self: *const Iterator, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_buf);
    }

    /// The returned entry is invalidated on the next call to `next`.
    pub fn next(self: *Iterator) !?Entry {
        var fba: std.heap.FixedBufferAllocator = .init(self.entry_buf);
        while (true) {
            const line = self.reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = self.reader.discardDelimiterInclusive('\n') catch |err2| switch (err2) {
                        error.EndOfStream => return null,
                        else => |e| return e,
                    };
                    continue;
                },
                else => |e| return e,
            } orelse return null;

            const escaped_path, const version = std.mem.cut(u8, line, " => ") orelse continue;
            const path = (std.json.parseFromSlice([]const u8, fba.allocator(), escaped_path, .{
                .allocate = .alloc_if_needed,
            }) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => continue,
            }).value;

            const is_semver = !std.meta.isError(std.SemanticVersion.parse(version));
            if (!is_semver or !Dir.path.isAbsolute(path)) {
                continue;
            }
            return .{
                .path = path,
                .version = version,
                .raw_line = line,
            };
        }
    }
};

/// Returns the previously selected version for the given path,
/// or `null` if there is no previous selection.
pub fn getVersion(
    allocator: std.mem.Allocator,
    io: Io,
    base_dir: Dir,
    path: []const u8,
) !?[]const u8 {
    const store = base_dir.openFile(io, STORE_FILENAME, .{
        .allow_directory = false,
        .lock = .shared,
        .lock_nonblocking = false,
    }) catch |err| switch (err) {
        error.FileNotFound,
        error.NameTooLong,
        error.BadPathName,
        => return null,
        else => |e| return e,
    };
    defer store.close(io);
    var store_buf: [16 * 1024]u8 = undefined;
    var reader = store.reader(io, &store_buf);

    var iter: Iterator = try .init(&reader.interface, allocator);
    defer iter.deinit(allocator);
    while (iter.next() catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    }) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            return try allocator.dupe(u8, entry.version);
        }
    }

    return null;
}

/// Inserts a new entry (from `path` and `version`) at the beginning,
/// then writes the existing entries from `reader`.
/// Invalid entries from `reader` are not written.
fn prependEntry(
    reader: *Io.Reader,
    writer: *Io.Writer,
    path: []const u8,
    version: []const u8,
) !void {
    try writer.print("{f} => {s}\n", .{
        std.json.fmt(path, .{ .emit_strings_as_arrays = false, .escape_unicode = false }),
        version,
    });

    var entry_buf: [Dir.max_path_bytes * 2]u8 = undefined;
    var entry_fba: std.heap.FixedBufferAllocator = .init(&entry_buf);
    var iter = Iterator.init(reader, entry_fba.allocator()) catch unreachable;
    defer iter.deinit(entry_fba.allocator());
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.path, path)) continue;
        var strs: [2][]const u8 = .{ entry.raw_line, "\n" };
        try writer.writeVecAll(&strs);
    }
}

pub fn addEntry(
    io: Io,
    base_dir: Dir,
    path: []const u8,
    version: []const u8,
) !void {
    const store = try base_dir.createFile(io, STORE_FILENAME, .{
        .read = true,
        .truncate = false,
        .exclusive = false,
        .lock = .exclusive,
        .lock_nonblocking = false,
    });
    defer store.close(io);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = store.reader(io, &read_buf);

    var new_store = try base_dir.createFileAtomic(io, STORE_FILENAME, .{ .replace = true });
    defer new_store.deinit(io);
    var write_buf: [16 * 1024]u8 = undefined;
    var writer = new_store.file.writer(io, &write_buf);

    // Write new entry at the start for fast retrival
    prependEntry(&reader.interface, &writer.interface, path, version) catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
    writer.end() catch |err| switch (err) {
        error.WriteFailed => return writer.err.?,
        else => |e| return e,
    };
    // TODO: this will probably always fail on Windows because the old store file is still open
    try new_store.replace(io);
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
