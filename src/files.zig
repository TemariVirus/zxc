const std = @import("std");
const log = std.log.default;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Environ = std.process.Environ;
const assert = std.debug.assert;
const fatal = std.process.fatal;

const builtin = @import("builtin");
const known_folders = @import("known-folders");
const fs = @import("fs.zig");
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
                isZigVersionInstalledDir(io, self.versionsDir(), entry.name))
            {
                return entry.name;
            }
        }
        return null;
    }
};

pub fn getBasePath(io: Io, environ: *const Environ.Map, buf: []u8) ![]u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const cache_path = try known_folders.getPath(
        io,
        fba.allocator(),
        environ,
        .cache,
    ) orelse return error.CacheDirNotFound;
    if (!Dir.path.isAbsolute(cache_path)) return error.CacheDirNotFound;
    return try fs.joinPathsInPlace(buf, cache_path.len, &.{BASE_DIR});
}

/// Opens and returns zxc's base directory.
pub fn openBaseDir(io: Io, environ: *const Environ.Map) Dir {
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const path = getBasePath(io, environ, &buf) catch |err|
        fatal("Failed to locate base dir: {t}", .{err});
    return Dir.cwd().createDirPathOpen(io, path, .{}) catch |err|
        fatal("Failed to open base dir '{s}': {t}", .{ path, err });
}

/// Opens and returns zxc's tmp directory with `.iterate = true`.
pub fn openTmpDir(io: Io, base_dir: Dir) !Dir {
    return try base_dir.createDirPathOpen(io, "tmp", .{ .open_options = .{ .iterate = true } });
}

const GetPerishableArgs = struct {
    allocator: Allocator,
    client: *std.http.Client,
    base_dir: Dir,
    base_path: []const u8,
    /// How long before the file is considered outdated.
    file_expiry: Io.Duration,
    /// Where to download the file from.
    fetch_uri: std.Uri,
};
fn getPerishableFile(
    comptime name: []const u8,
    comptime Return: type,
    comptime E: type,
    comptime getIfValid: fn (Allocator, Io, Io.File, Io.Duration) E!Return,
    args: GetPerishableArgs,
) !Return {
    const io = args.client.io;

    happy: {
        const file = args.base_dir.openFile(io, args.base_path, .{
            .allow_directory = false,
            .mode = .read_only,
            .lock = .shared,
            .lock_nonblocking = false,
        }) catch |err| switch (err) {
            error.IsDir => {
                args.base_dir.deleteTree(io, args.base_path) catch {};
                break :happy;
            },
            error.FileNotFound => break :happy,
            error.NoSpaceLeft,
            error.PathAlreadyExists,
            error.WouldBlock,
            => unreachable,
            else => |e| return e,
        };
        defer file.close(io);
        if (getIfValid(args.allocator, io, file, args.file_expiry)) |contents| {
            return contents;
        } else |_| break :happy;
    }

    const file = args.base_dir.createFile(io, args.base_path, .{
        .read = true,
        .truncate = true,
        .lock = .exclusive,
        .lock_nonblocking = false,
    }) catch |err| switch (err) {
        error.PathAlreadyExists, error.WouldBlock => unreachable,
        else => |e| return e,
    };
    defer file.close(io);
    // Did someone else fetch a new file while we were waiting?
    if (getIfValid(args.allocator, io, file, args.file_expiry)) |contents| {
        return contents;
    } else |_| {}

    log.info("Fetching {s}...", .{name});
    var write_buf: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    if (http.fetchToFile(args.client, args.fetch_uri, &file_writer)) |_| {
        log.info("Fetched {s}.", .{name});
    } else |err| {
        log.warn("Failed to fetch {s}: {t}", .{ name, err });
    }

    // If the fetch failed, return the old file anyway
    return getIfValid(args.allocator, io, file, .max);
}

/// Returns the contents of the index file if it is valid.
fn getIndexIfValid(
    allocator: Allocator,
    io: Io,
    index_file: Io.File,
    max_age: Io.Duration,
) ![]const u8 {
    const stat = try index_file.stat(io);
    if (stat.size == 0) {
        return error.NoIndex;
    }
    const age = stat.mtime.untilNow(io, .real);
    if (age.toNanoseconds() > max_age.toNanoseconds()) {
        return error.Outdated;
    }

    const content = fs.readAllExact(allocator, io, index_file, stat.size) catch |err| switch (err) {
        error.WrongSize => return error.IndexFileChanged,
        else => |e| return e,
    };
    errdefer allocator.free(content);
    var stack_buf: [INDEX_JSON_STACK_SIZE]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack_buf);
    if (!try std.json.validate(fba.allocator(), content)) {
        return error.BadIndexFile;
    }
    return content;
}

/// Returns the Zig index, downloading from the internet if necessary.
pub fn getIndex(allocator: Allocator, client: *std.http.Client, base_dir: Dir) ![]const u8 {
    const INDEX_URI = comptime std.Uri.parse("https://ziglang.org/download/index.json") catch unreachable;
    const R = @typeInfo(@TypeOf(getIndexIfValid)).@"fn".return_type.?;
    return getPerishableFile(
        "index",
        []const u8,
        @typeInfo(R).error_union.error_set,
        getIndexIfValid,
        .{
            .allocator = allocator,
            .client = client,
            .base_dir = base_dir,
            .base_path = "index.json",
            .file_expiry = .fromNanoseconds(1 * std.time.ns_per_day),
            .fetch_uri = INDEX_URI,
        },
    );
}

/// Returns a list of mirrors if the mirrors file is valid.
/// The strings in the list come from a single backing allocation, so an arena-style allocator must be used.
fn getMirrorsIfValid(
    allocator: Allocator,
    io: Io,
    mirrors_file: Io.File,
    max_age: Io.Duration,
) ![][]const u8 {
    const stat = try mirrors_file.stat(io);
    if (stat.size == 0) {
        return error.NoMirrors;
    }
    const age = stat.mtime.untilNow(io, .real);
    if (age.toNanoseconds() > max_age.toNanoseconds()) {
        return error.Outdated;
    }

    const content = fs.readAllExact(allocator, io, mirrors_file, stat.size) catch |err| switch (err) {
        error.WrongSize => return error.MirrorsFileChanged,
        else => |e| return e,
    };
    errdefer allocator.free(content);

    const line_count = std.mem.countScalar(u8, content, '\n');
    if (line_count == 0) {
        return error.BadMirrorsFile;
    }
    var mirrors: std.ArrayList([]const u8) = try .initCapacity(allocator, line_count);
    errdefer mirrors.deinit(allocator);

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        mirrors.appendAssumeCapacity(line);
    }
    if (mirrors.items.len != line_count) {
        return error.BadMirrorsFile;
    }

    const Rng = std.Random.ChaCha;
    var rng: Rng = rng: {
        var seed: [Rng.secret_seed_length]u8 = undefined;
        io.random(&seed);
        break :rng .init(seed);
    };
    rng.random().shuffle([]const u8, mirrors.items);
    return mirrors.items;
}

/// Returns the list of mirrors, downloading from the internet if necessary.
/// The strings in the list come from a single backing allocation, so an arena-style allocator must be used.
pub fn getMirrors(
    arena: *std.heap.ArenaAllocator,
    client: *std.http.Client,
    base_dir: Dir,
) ![][]const u8 {
    const MIRRORS_URI = comptime std.Uri.parse("https://ziglang.org/download/community-mirrors.txt") catch unreachable;
    const R = @typeInfo(@TypeOf(getMirrorsIfValid)).@"fn".return_type.?;
    return getPerishableFile(
        "mirrors",
        [][]const u8,
        @typeInfo(R).error_union.error_set,
        getMirrorsIfValid,
        .{
            .allocator = arena.allocator(),
            .client = client,
            .base_dir = base_dir,
            .base_path = "mirrors.txt",
            .file_expiry = .fromNanoseconds(1 * std.time.ns_per_day),
            .fetch_uri = MIRRORS_URI,
        },
    );
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

/// Extracts `tarball` into `dir`.
/// The tarball format and extracted directory name is infered from `tarball_name`.
/// Returns the infered extracted directory name.
pub fn extractZigTarball(
    allocator: Allocator,
    io: Io,
    tarball: Io.File,
    tarball_name: []const u8,
    dir: Dir,
) ![]const u8 {
    const buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buf);
    var reader = tarball.reader(io, buf);

    const tarball_format = ArchiveFormat.fromFileName(tarball_name) orelse
        return error.UnsupportedFormat;
    const dir_name = switch (tarball_format) {
        .xz => tarball_name[0 .. tarball_name.len - tarball_format.extension().len],
        .zip => tarball_name[0 .. tarball_name.len - tarball_format.extension().len],
    };
    try dir.deleteTree(io, dir_name);
    switch (tarball_format) {
        .xz => {
            var d: std.compress.xz.Decompress = try .init(&reader.interface, allocator, &.{});
            defer d.deinit();
            try std.tar.extract(io, dir, &d.reader, .{});
        },
        .zip => try std.zip.extract(dir, &reader, .{}),
    }
    return dir_name;
}

/// Returns whether the given Zig version is installed.
pub fn isZigVersionInstalled(io: Io, versions_path: []const u8, version: []const u8) bool {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const path = Dir.path.join(
        fba.allocator(),
        &.{ versions_path, version, ZIG_NAME },
    ) catch return false;
    Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// Similar to `isZigVersionInstalled`, but takes an open file handle to the versions directory.
pub fn isZigVersionInstalledDir(io: Io, versions_dir: Dir, version: []const u8) bool {
    var path_buf: [Dir.max_name_bytes + 1 + ZIG_NAME.len]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const path = Dir.path.join(fba.allocator(), &.{ version, ZIG_NAME }) catch return false;
    versions_dir.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// Similar to `isZigVersionInstalled`, but checks if installed version
/// is the latest when `version` is not a semantic version (i.e., assumed to be a rolling release).
/// Assumes `index` contains the latest version.
pub fn isNewestVersionInstalled(
    io: Io,
    index: []const u8,
    versions_path: []const u8,
    version: []const u8,
) !bool {
    const is_semver = !std.meta.isError(std.SemanticVersion.parse(version));
    if (is_semver) {
        return isZigVersionInstalled(io, versions_path, version);
    }

    var probe_buf: [64]u8 = undefined;
    const installed_version = probeInstalledVersion(io, versions_path, version, &probe_buf) orelse return false;
    var iter: IndexIterator = undefined;
    try iter.init(index);
    while (try iter.next()) |zig| {
        if (!std.mem.eql(u8, zig.name, version)) continue;
        if (zig.version == null) return false;
        return std.mem.eql(u8, zig.version.?, installed_version);
    }
    return false;
}

/// Returns the actual version of `version` if it is installed, or `null` otherwise.
/// `buffer` is used to store the result.
pub fn probeInstalledVersion(
    io: Io,
    versions_path: []const u8,
    version: []const u8,
    buffer: []u8,
) ?[]const u8 {
    assert(Dir.path.isAbsolute(versions_path));

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const path = Dir.path.join(
        fba.allocator(),
        &.{ versions_path, version, ZIG_NAME },
    ) catch return null;
    var zig_proc = std.process.spawn(io, .{
        .argv = &.{ path, "version" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer zig_proc.kill(io);

    var reader = zig_proc.stdout.?.readerStreaming(io, buffer);
    return reader.interface.takeDelimiter('\n') catch |err| {
        log.warn("Failed to probe installed {s} version: {t}", .{
            version,
            switch (err) {
                error.ReadFailed => reader.err.?,
                else => err,
            },
        });
        return null;
    };
}

/// Appends installed Zig versions to `versions`,
/// and returns a mapping of name to index inside `versions`.
fn collectInstalledVersions(
    allocator: Allocator,
    io: Io,
    versions: *std.ArrayList(ZigVersion),
    versions_dir: Dir,
    versions_path: []const u8,
) !std.StringHashMap(usize) {
    const old_len = versions.items.len;
    var installed: std.StringHashMap(usize) = .init(allocator);
    errdefer {
        for (versions.items[old_len..]) |item| {
            allocator.free(item.name);
            if (item.version) |v| allocator.free(v);
        }
        versions.shrinkRetainingCapacity(old_len);
        installed.deinit();
    }

    var iter: InstalledZigIterator = .init(versions_dir);
    while (iter.next(io)) |name| {
        const is_semver = !std.meta.isError(std.SemanticVersion.parse(name));
        const version = blk: {
            if (is_semver) break :blk null;
            var probe_buf: [64]u8 = undefined;
            const v = probeInstalledVersion(io, versions_path, name, &probe_buf) orelse break :blk null;
            if (std.mem.eql(u8, name, v)) break :blk null;
            break :blk try allocator.dupe(u8, v);
        };
        errdefer if (version) |v| allocator.free(v);

        const duped_name = try allocator.dupe(u8, name);
        errdefer allocator.free(duped_name);
        try installed.put(duped_name, versions.items.len);
        try versions.append(allocator, .{
            .name = duped_name,
            .version = version,
            .installed = true,
        });
    }

    return installed;
}

/// Returns all Zig verisons, both installed and online, without duplicates.
/// An arena-style allocator must be used.
pub fn getAllVersions(
    allocator: Allocator,
    io: Io,
    versions_path: []const u8,
    index: []const u8,
) ![]ZigVersion {
    var versions: std.ArrayList(ZigVersion) = .empty;
    errdefer versions.deinit(allocator);

    const versions_dir = Dir.openDirAbsolute(
        io,
        versions_path,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => |e| return e,
    };
    defer if (versions_dir) |vd| vd.close(io);
    var installed: std.StringHashMap(usize) = if (versions_dir) |vd|
        try collectInstalledVersions(allocator, io, &versions, vd, versions_path)
    else
        .init(allocator);
    defer installed.deinit();

    var index_iter: IndexIterator = undefined;
    try index_iter.init(index);
    while (try index_iter.next()) |entry| {
        const is_semver = !std.meta.isError(std.SemanticVersion.parse(entry.name));
        if (installed.get(entry.name)) |idx| blk: {
            if (is_semver) continue;
            const old_ver = versions.items[idx].version orelse break :blk;
            const new_ver = entry.version orelse break :blk;
            if (std.mem.eql(u8, old_ver, new_ver)) continue;
        }
        try versions.append(allocator, .{
            .name = entry.name,
            .version = if (entry.version != null and !is_semver)
                entry.version.?
            else
                null,
            .installed = false,
        });
    }

    return try versions.toOwnedSlice(allocator);
}
