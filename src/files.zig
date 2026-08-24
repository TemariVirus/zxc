const std = @import("std");
const log = std.log.default;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Environ = std.process.Environ;
const fatal = std.process.fatal;

const builtin = @import("builtin");
const known_folders = @import("known-folders");
const http = @import("http.zig");
const json = @import("json.zig");

pub const SELF_TARGET = std.fmt.comptimePrint("{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag });
pub const BASE_DIR = "zxc";
pub const VERSIONS_DIR = "versions";
pub const ZIG_NAME = switch (builtin.target.os.tag) {
    .windows => "zig.exe",
    else => "zig",
};
/// The index is validated using a scanner with this stack size.
/// Thus, any scanners using this stack size will never return an error when
/// parsing the index.
pub const INDEX_JSON_STACK_SIZE = 256;
const MAX_INDEX_AGE: Io.Duration = .fromNanoseconds(1 * std.time.ns_per_day);

pub const ArchiveFormat = enum {
    xz,
    zip,

    pub fn fromFileName(name: []const u8) ?ArchiveFormat {
        return if (std.mem.endsWith(u8, name, ".tar.xz"))
            .xz
        else if (std.mem.endsWith(u8, name, ".zip"))
            .zip
        else
            null;
    }

    pub fn extension(self: ArchiveFormat) []const u8 {
        return switch (self) {
            .xz => ".tar.xz",
            .zip => ".zip",
        };
    }
};

pub const TarballInfo = struct {
    fallback_url: []const u8,
    name: []const u8,
    size: u64,
};

pub const ZigVersion = struct {
    /// The name that would be used in the versions directory.
    name: []const u8,
    /// The zig version. If `null`, the version is the same as `name`.
    version: ?[]const u8,
    installed: bool,

    fn orderMaybeSemanticVersion(lhs: []const u8, rhs: []const u8) std.math.Order {
        blk: {
            const l = std.SemanticVersion.parse(lhs) catch break :blk;
            const r = std.SemanticVersion.parse(rhs) catch break :blk;
            return l.order(r);
        }
        return std.mem.order(u8, lhs, rhs);
    }

    /// Returns whether `lhs` comes after `rhs` in a sorted array.
    pub fn greaterThan(_: void, lhs: ZigVersion, rhs: ZigVersion) bool {
        switch (orderMaybeSemanticVersion(lhs.name, rhs.name)) {
            .lt => return false,
            .eq => {},
            .gt => return true,
        }
        if (rhs.version == null) return false;
        if (lhs.version == null) return true;
        return orderMaybeSemanticVersion(lhs.version.?, rhs.version.?) == .gt;
    }

    pub fn format(self: ZigVersion, writer: *Io.Writer) Io.Writer.Error!void {
        writer.writeAll(self.name) catch {};
        if (self.version) |ver| {
            writer.print(" ({s})", .{ver}) catch {};
        }
        if (self.installed) {
            writer.writeAll(" [Installed]") catch {};
        }
    }
};

/// Iterates through the Zig versions in the index.
pub const IndexIterator = struct {
    stack_buf: [INDEX_JSON_STACK_SIZE]u8,
    fba: std.heap.FixedBufferAllocator,
    /// This scanner will never return an error
    scanner: std.json.Scanner,

    pub const Error = error{UnexpectedFormat};

    pub const Entry = struct {
        name: []const u8,
        version: ?[]const u8,
    };

    pub fn init(self: *IndexIterator, index: []const u8) Error!void {
        self.fba = .init(&self.stack_buf);
        self.scanner = .initCompleteInput(self.fba.allocator(), index);
        switch (self.scanner.next() catch unreachable) {
            .object_begin => {},
            else => return Error.UnexpectedFormat,
        }
    }

    pub fn next(self: *IndexIterator) Error!?Entry {
        while (true) switch (self.scanner.next() catch unreachable) {
            .string => |name| {
                switch (self.scanner.next() catch unreachable) {
                    .object_begin => {},
                    else => return Error.UnexpectedFormat,
                }
                // "version" is always the first key if it exists
                const version = json.parseValueIfEqlKey([]const u8, &self.scanner, "version") catch |err| switch (err) {
                    error.NoMoreKeys => continue,
                    error.UnexpectedToken => return Error.UnexpectedFormat,
                    else => unreachable,
                };
                json.skipToKey(&self.scanner, SELF_TARGET) catch |err| switch (err) {
                    error.NoMoreKeys => continue,
                    else => unreachable,
                };

                self.scanner.skipValue() catch unreachable;
                json.skipToEndOfObject(&self.scanner) catch unreachable;
                return .{ .name = name, .version = version };
            },
            .object_end, .end_of_document => return null,
            else => unreachable,
        };
    }
};

/// Iterates through the Zig versions installed in the versions directory.
pub const InstalledZigIterator = struct {
    dir_iter: Dir.Iterator,

    /// `versions_dir` must be opened with `.iterate = true`
    pub fn init(versions_dir: Dir) InstalledZigIterator {
        return .{ .dir_iter = versions_dir.iterate() };
    }

    pub fn versionsDir(self: InstalledZigIterator) Dir {
        return self.dir_iter.reader.dir;
    }

    pub fn next(self: *InstalledZigIterator, io: Io) ?[]const u8 {
        while (self.dir_iter.next(io) catch |err| fatal("Failed to iterate versions folder: {t}", .{err})) |entry| {
            if (entry.kind == .directory and
                isZigVersionInstalled(io, self.versionsDir(), entry.name))
            {
                return entry.name;
            }
        }
        return null;
    }

    /// Adds all installed versions into the set.
    /// Added versions are not freed on error.
    pub fn collectSet(io: Io, versions_dir: Dir, set: *std.StringHashMap(void)) Allocator.Error!void {
        var iter: InstalledZigIterator = .init(versions_dir);
        while (iter.next(io)) |version| {
            const name = try set.allocator.dupe(u8, version);
            errdefer set.allocator.free(name);
            try set.put(name, {});
        }
    }
};

/// Returns whether the given Zig version is installed in `versions_dir`.
pub fn isZigVersionInstalled(io: Io, versions_dir: Dir, version: []const u8) bool {
    var path_buf: [Dir.max_name_bytes + 1 + ZIG_NAME.len]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const path = Dir.path.join(fba.allocator(), &.{ version, ZIG_NAME }) catch return false;
    versions_dir.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// Similar to `isZigVersionInstalled`, but checks if installed master version
/// is the latest when `version` is "master".
/// Assumes `index` contains the latest master version.
pub fn isNewestVersionInstalled(
    io: Io,
    index: []const u8,
    versions_dir: Dir,
    version: []const u8,
) !bool {
    if (!std.mem.eql(u8, version, "master")) {
        return isZigVersionInstalled(io, versions_dir, version);
    }

    var buf: [64]u8 = undefined;
    const installed_version = installedMasterVersion(io, versions_dir, &buf) orelse return false;
    var iter: IndexIterator = undefined;
    try iter.init(index);
    while (try iter.next()) |zig| {
        if (!std.mem.eql(u8, zig.name, "master")) continue;
        if (zig.version == null) return false;
        return std.mem.eql(u8, zig.version.?, installed_version);
    }
    return false;
}

/// Returns the actual version of "master" if it is installed, or `null` otherwise.
/// `buffer` is used to store the result.
pub fn installedMasterVersion(io: Io, versions_dir: Dir, buffer: []u8) ?[]const u8 {
    // TODO: replace when spawnPath is implemented
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const path = versions_dir.realPathFileAlloc(
        io,
        "master" ++ Dir.path.sep_str ++ ZIG_NAME,
        fba.allocator(),
    ) catch return null;
    var zig_proc = std.process.spawn(io, .{
        .argv = &.{ path, "version" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer zig_proc.kill(io);

    var reader = zig_proc.stdout.?.reader(io, buffer);
    return reader.interface.takeDelimiter('\n') catch |err| {
        log.warn("Failed to probe installed master verion: {t}", .{switch (err) {
            error.ReadFailed => reader.err.?,
            else => err,
        }});
        return null;
    };
}

/// Returns all Zig verisons, both installed and online, without duplicates.
/// An arena-style allocator must be used.
pub fn getAllVersions(
    allocator: Allocator,
    io: Io,
    base_dir: Dir,
    index: []const u8,
) ![]ZigVersion {
    const versions_dir = try base_dir.openDir(io, VERSIONS_DIR, .{ .iterate = true });
    defer versions_dir.close(io);

    var installed: std.StringHashMap(void) = .init(allocator);
    try InstalledZigIterator.collectSet(io, versions_dir, &installed);

    const master_ver_buf = try allocator.alloc(u8, 64);
    const master_ver = if (installed.contains("master"))
        installedMasterVersion(io, versions_dir, master_ver_buf)
    else
        null;

    return getAllVersionsInner(allocator, master_ver, index, installed);
}

/// Returns all Zig verisons, both installed and online, without duplicates.
/// Strings inside the result point inside `master_ver`, `index` and `installed_names`,
/// rather than being allocated seperately.
pub fn getAllVersionsInner(
    allocator: Allocator,
    master_ver: ?[]const u8,
    index: []const u8,
    installed_names: std.StringHashMap(void),
) ![]ZigVersion {
    var versions: std.ArrayList(ZigVersion) = .empty;
    errdefer versions.deinit(allocator);

    var installed_iter = installed_names.keyIterator();
    while (installed_iter.next()) |name| {
        try versions.append(allocator, .{
            .name = name.*,
            .version = if (std.mem.eql(u8, name.*, "master")) master_ver else null,
            .installed = true,
        });
    }

    var index_iter: IndexIterator = undefined;
    try index_iter.init(index);
    while (try index_iter.next()) |entry| {
        if (installed_names.contains(entry.name)) {
            if (!std.mem.eql(u8, entry.name, "master")) continue;
            if (master_ver != null and
                entry.version != null and
                std.mem.eql(u8, master_ver.?, entry.version.?)) continue;
        }
        try versions.append(allocator, .{
            .name = entry.name,
            .version = if (entry.version != null and !std.mem.eql(u8, entry.name, entry.version.?))
                entry.version.?
            else
                null,
            .installed = false,
        });
    }

    return versions.toOwnedSlice(allocator);
}

/// Opens and returns zxc's base directory.
pub fn openBaseDir(allocator: Allocator, io: Io, environ: *const Environ.Map) Dir {
    const FALLBACK_BASE_PATH = comptime std.fmt.comptimePrint("{f}", .{Dir.path.fmtJoin(
        &.{ "~", "." ++ BASE_DIR },
    )});
    blk: {
        if (known_folders.getPath(
            io,
            allocator,
            environ,
            .cache,
        ) catch break :blk) |cache_path| {
            defer allocator.free(cache_path);
            const path = Dir.path.join(allocator, &.{ cache_path, BASE_DIR }) catch break :blk;
            defer allocator.free(path);
            return Dir.cwd().createDirPathOpen(io, path, .{}) catch break :blk;
        }
    }
    return Dir.cwd().createDirPathOpen(io, FALLBACK_BASE_PATH, .{}) catch |err| {
        fatal("Failed to open base dir '{s}': {t}", .{ FALLBACK_BASE_PATH, err });
    };
}

/// Opens and returns zxc's tmp directory with `.iterate = true`.
pub fn openTmpDir(io: Io, base_dir: Dir) !Dir {
    return try base_dir.createDirPathOpen(io, "tmp", .{ .open_options = .{ .iterate = true } });
}

/// Extracts `tarball` into `dst_dir` as a directory named `version_name`.
/// The tarball is first extracted into `tmp_dir` before being renamed to (try to) make the operation atomic.
pub fn extractZigTarball(
    allocator: Allocator,
    io: Io,
    dst_dir: Dir,
    tmp_dir: Dir,
    tarball: Io.File,
    tarball_name: []const u8,
    version_name: []const u8,
) !void {
    const buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buf);
    var reader = tarball.reader(io, buf);

    const tarball_format = ArchiveFormat.fromFileName(tarball_name) orelse unreachable;
    const dir_name = switch (tarball_format) {
        .xz => tarball_name[0 .. tarball_name.len - tarball_format.extension().len],
        .zip => tarball_name[0 .. tarball_name.len - tarball_format.extension().len],
    };
    try tmp_dir.deleteTree(io, dir_name);
    switch (tarball_format) {
        .xz => {
            var d: std.compress.xz.Decompress = try .init(&reader.interface, allocator, &.{});
            defer d.deinit();
            try std.tar.extract(io, tmp_dir, &d.reader, .{});
        },
        .zip => try std.zip.extract(tmp_dir, &reader, .{}),
    }
    try dst_dir.deleteTree(io, version_name);
    try Dir.rename(tmp_dir, dir_name, dst_dir, version_name, io);
}

/// Returns the contents of the index file if it is valid.
fn getIndexIfValid(allocator: Allocator, io: Io, index_file: Io.File) ![]const u8 {
    const stat = try index_file.stat(io);
    if (stat.size == 0) {
        return error.NoIndex;
    }
    const age = stat.mtime.untilNow(io, .real);
    if (age.toNanoseconds() > MAX_INDEX_AGE.toNanoseconds()) {
        return error.OutdatedIndex;
    }

    const content = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(content);
    // TODO: use reader interface instead of foring positional reading
    if (try index_file.readPositionalAll(io, content, 0) != content.len) {
        return error.IndexFileChanged;
    }

    var stack_buf: [INDEX_JSON_STACK_SIZE]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack_buf);
    if (!try std.json.validate(fba.allocator(), content)) {
        return error.BadIndexFile;
    }
    return content;
}

// TODO: use old file if unable to fetch
/// Returns the Zig index, downloading from the internet if necessary.
pub fn getIndex(
    allocator: Allocator,
    io: Io,
    client: *std.http.Client,
    base_dir: Dir,
) ![]const u8 {
    const INDEX_URI = comptime std.Uri.parse("https://ziglang.org/download/index.json") catch unreachable;
    const INDEX_PATH = "index.json";

    const index_file = try base_dir.createFile(io, INDEX_PATH, .{
        .read = true,
        .truncate = false,
    });
    defer index_file.close(io);
    if (getIndexIfValid(allocator, io, index_file)) |contents| {
        return contents;
    } else |_| {}

    log.info("Fetching index...", .{});
    var write_buf: [16 * 1024]u8 = undefined;
    var file_writer = index_file.writer(io, &write_buf);
    const result = try http.fetch(client, INDEX_URI);
    defer result.deinit();
    _ = try result.reader.streamRemaining(&file_writer.interface);
    try file_writer.end();

    const contents = try getIndexIfValid(allocator, io, index_file);
    log.info("Fetched index.", .{});
    return contents;
}

/// Returns a list of mirrors if the mirrors file is valid.
/// The strings in the list come from a single backing allocation, so an arena-style allocator must be used.
fn getMirrorsIfValid(allocator: Allocator, io: Io, mirrors_file: Io.File) ![][]const u8 {
    const stat = try mirrors_file.stat(io);
    if (stat.size == 0) {
        return error.NoMirrors;
    }
    const age = stat.mtime.untilNow(io, .real);
    if (age.toNanoseconds() > MAX_INDEX_AGE.toNanoseconds()) {
        return error.OutdatedMirrors;
    }

    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    if (try mirrors_file.readPositionalAll(io, buf, 0) != buf.len) {
        return error.MirrorsFileChanged;
    }

    const line_count = std.mem.countScalar(u8, buf, '\n');
    if (line_count <= 0) {
        return error.BadMirrorsFile;
    }
    var mirrors: std.ArrayList([]const u8) = try .initCapacity(allocator, line_count);
    errdefer mirrors.deinit(allocator);

    var lines = std.mem.tokenizeScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        mirrors.appendAssumeCapacity(line);
    }
    if (mirrors.items.len != line_count) {
        return error.BadMirrorsFile;
    }
    return mirrors.items;
}

// TODO: use old file if unable to fetch
/// Returns the list of mirrors, downloading from the internet if necessary.
/// The strings in the list come from a single backing allocation, so an arena-style allocator must be used.
pub fn getMirrors(
    arena: *std.heap.ArenaAllocator,
    io: Io,
    client: *std.http.Client,
    base_dir: Dir,
) ![][]const u8 {
    const MIRRORS_URI = comptime std.Uri.parse("https://ziglang.org/download/community-mirrors.txt") catch unreachable;
    const MIRRORS_PATH = "mirrors.txt";

    const mirrors_file = try base_dir.createFile(io, MIRRORS_PATH, .{
        .read = true,
        .truncate = false,
    });
    defer mirrors_file.close(io);
    if (getMirrorsIfValid(arena.allocator(), io, mirrors_file)) |mirrors| {
        return mirrors;
    } else |_| {}

    log.info("Fetching mirrors...", .{});
    var write_buf: [1024]u8 = undefined;
    var file_writer = mirrors_file.writer(io, &write_buf);
    const result = try http.fetch(client, MIRRORS_URI);
    defer result.deinit();
    _ = try result.reader.streamRemaining(&file_writer.interface);
    try file_writer.end();

    const mirrors = try getMirrorsIfValid(arena.allocator(), io, mirrors_file);
    log.info("Fetched mirrors.", .{});
    return mirrors;
}

/// Returns info about the tarball for `zig_version` on `target`, or `null` if it does not exist.
/// The result contains slices into `index`.
pub fn getTarballInfo(index: []const u8, zig_version: []const u8, target: []const u8) error{UnexpectedFormat}!?TarballInfo {
    var stack_buf: [INDEX_JSON_STACK_SIZE]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack_buf);
    // This scanner will never return an error
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), index);

    json.skipToObjectKey(&scanner, zig_version) catch |err| switch (err) {
        error.NoMoreKeys => return null,
        else => return error.UnexpectedFormat,
    };
    json.skipToObjectKey(&scanner, target) catch |err| switch (err) {
        error.NoMoreKeys => return null,
        else => return error.UnexpectedFormat,
    };

    var url: ?[]const u8 = null;
    var size: ?u64 = null;
    switch (scanner.next() catch unreachable) {
        .object_begin => {},
        else => return error.UnexpectedFormat,
    }
    while (url == null or size == null) {
        switch (scanner.next() catch unreachable) {
            .string => |key| if (std.mem.eql(u8, key, "tarball")) {
                url = json.parseNext([]const u8, &scanner) catch return error.UnexpectedFormat;
            } else if (std.mem.eql(u8, key, "size")) {
                size = json.parseNext(u64, &scanner) catch return error.UnexpectedFormat;
            } else {
                scanner.skipValue() catch unreachable;
            },
            .object_end => return null,
            else => unreachable,
        }
    }

    return if (std.mem.cutScalarLast(u8, url.?, '/')) |cuts|
        TarballInfo{
            .fallback_url = url.?,
            .name = cuts[1],
            .size = size.?,
        }
    else
        error.UnexpectedFormat;
}
