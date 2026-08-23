const std = @import("std");
const log = std.log.default;
const Io = std.Io;
const Dir = Io.Dir;
const Rng = std.Random.ChaCha;
const fatal = std.process.fatal;

const files = @import("files.zig");
const http = @import("http.zig");

/// Installs the zig version into `versions_dir`.
/// The comparessed tarball is temporarily stored in `tmp_dir`.
fn installZig(
    client: *std.http.Client,
    tmp_dir: Dir,
    versions_dir: Dir,
    mirrors: [][]const u8,
    index: []const u8,
    version: []const u8,
    stdout: *Io.Writer,
) void {
    // TODO: race using file locks to ensure only one process tries to install the zig version at a time
    const allocator = client.allocator;
    const io = client.io;

    log.info("Fetching Zig version {s}...", .{version});

    var rng: Rng = rng: {
        var seed: [Rng.secret_seed_length]u8 = undefined;
        io.random(&seed);
        break :rng .init(seed);
    };
    rng.random().shuffle([]const u8, mirrors);

    const tarball_info = files.getTarballInfo(index, version, files.SELF_TARGET) catch
        fatal("Unexpected format for index file. Please update your zxc version.", .{}) orelse
        fatal("No tarball exists for version {s} on target {s}", .{ version, files.SELF_TARGET });
    _ = files.ArchiveFormat.fromFileName(tarball_info.name) orelse
        fatal("Unsupported archive format: {s}", .{Dir.path.extension(tarball_info.name)});
    // Prevent path traversal
    for (tarball_info.name) |c| {
        if (Dir.path.isSep(c)) fatal("Invalid tarball name: {s}\n", .{tarball_info.name});
    }

    // TODO: respect per-version file lock
    // base_dir.deleteTree(io, TMP_DIR_SUBPATH) catch {}; // Try to clean up stuff from previous crashes

    const archive_file = tmp_dir.createFile(io, tarball_info.name, .{ .read = true }) catch |err|
        fatal("Failed to create tarball file: {t}", .{err});
    defer {
        archive_file.close(io);
        log.info("Cleaning up extracted tarball...", .{});
        tmp_dir.deleteFile(io, tarball_info.name) catch {};
    }
    archive_file.setLength(io, tarball_info.size) catch {};

    for (mirrors) |mirror| {
        log.info("Trying mirror {s}...", .{mirror});
        http.downloadZig(client, mirror, tarball_info, archive_file, stdout) catch continue;
        break;
    } else {
        log.warn("Failed to download zig from all mirrors. Trying ziglang.org as fallback...", .{});
        http.downloadZig(client, tarball_info.fallback_url, tarball_info, archive_file, stdout) catch
            fatal("Exhausted all sources. Exiting.", .{});
    }

    {
        const archive_buf = allocator.alloc(u8, 64 * 1024) catch fatal("Out of memory", .{});
        defer allocator.free(archive_buf);
        log.info("Extracting tarball...", .{});
        var reader = archive_file.reader(io, archive_buf);
        files.extractZigTarball(allocator, io, versions_dir, tmp_dir, &reader, tarball_info.name, version) catch |err|
            fatal("Failed to extract tarball: {t}", .{err});
    }

    log.info("Successfully installed zig {s}!", .{version});
}

/// Returns the zig version from `zon_path`, or null if the path does not exist.
/// If the file at `zon_path` does not store the zig version, `error.ParseZon` is returned.
fn getZigVersionFromBuildZigZon(
    allocator: std.mem.Allocator,
    io: Io,
    zon_path: []const u8,
) !?[]const u8 {
    const text = Dir.cwd().readFileAllocOptions(
        io,
        zon_path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return null,
        else => |e| return e,
    };
    defer allocator.free(text);

    const zon = try std.zon.parse.fromSliceAlloc(
        struct { minimum_zig_version: []const u8 },
        allocator,
        text,
        null,
        .{ .ignore_unknown_fields = true },
    );
    errdefer std.zon.parse.free(allocator, zon);

    _ = std.SemanticVersion.parse(zon.minimum_zig_version) catch return error.ParseZon;
    return zon.minimum_zig_version;
}

fn userSelectZigVersion(
    index: []const u8,
    stdin: *Io.File.Reader,
    stdout: *Io.Writer,
) struct { []const u8, bool } {
    _ = stdin; // autofix
    _ = index; // autofix
    stdout.writeAll("Select Zig version:\n") catch {};
    stdout.flush() catch {};
    @panic("TODO: ask user to pick zig version");
}

/// Tries to detect the required zig version based on the current working directory.
fn detectZigVersion(allocator: std.mem.Allocator, io: Io, stdout: *Io.Writer) ?[]const u8 {
    const filename = "build.zig.zon";

    // This will usually succeed, allowing us to skip a syscall to get the current path
    if (getZigVersionFromBuildZigZon(allocator, io, filename) catch |err| switch (err) {
        error.ParseZon => {
            stdout.writeAll("Failed to detect Zig version from build.zig.zon.\n") catch {};
            stdout.flush() catch {};
            return null;
        },
        else => fatal("Failed to parse build.zig.zon: {t}", .{err}),
    }) |ver| return ver;

    const path_buf = allocator.alloc(u8, Dir.max_path_bytes + 1 + filename.len) catch fatal("Out of memory", .{});
    defer allocator.free(path_buf);
    var path = path: {
        var n = std.process.currentPath(io, path_buf) catch |err| switch (err) {
            error.NameTooLong => unreachable,
            else => fatal("Unable to get current working directory: {t}", .{err}),
        };
        if (n > Dir.max_path_bytes) fatal("Current working directory name was too long.", .{});

        // Append filename to path
        if (n > 0 and path_buf[n - 1] == Dir.path.sep) n -= 1;
        path_buf[n] = Dir.path.sep;
        @memcpy(path_buf[n + 1 ..][0..filename.len], filename);
        break :path path_buf[0 .. n + 1 + filename.len];
    };

    while (true) {
        const cwd = Dir.path.dirname(path) orelse unreachable;
        const parent = Dir.path.dirname(cwd) orelse {
            stdout.writeAll("No build.zig.zon found.\n") catch {};
            stdout.flush() catch {};
            return null;
        };
        @memcpy(path[parent.len + 1 ..][0..filename.len], filename);
        path = path[0 .. parent.len + 1 + filename.len];

        if (getZigVersionFromBuildZigZon(allocator, io, path) catch |err| switch (err) {
            error.ParseZon => {
                stdout.writeAll("Failed to detect Zig version from build.zig.zon.\n") catch {};
                stdout.flush() catch {};
                return null;
            },
            else => fatal("Failed to parse build.zig.zon: {t}", .{err}),
        }) |ver| return ver;
    }

    return null;
}

/// Returns a version in `index` that is compatible with `version`, or `null` if it does not exist.
/// The returned version is a slice from `index`.
fn getCompatibleZigVersion(index: []const u8, version: []const u8) ?[]const u8 {
    const SemVer = std.SemanticVersion;
    var compatible_version: ?[]const u8 = null;
    const wanted_semver: ?SemVer = SemVer.parse(version) catch null;

    var index_iter: files.IndexIterator = undefined;
    index_iter.init(index) catch
        fatal("Unexpected format for index file. Please update your zxc version.", .{});
    while (index_iter.next() catch
        fatal("Unexpected format for index file. Please update your zxc version.", .{})) |entry|
    {
        if (wanted_semver) |wanted| {
            const online = SemVer.parse(entry.alt_version orelse entry.version) catch continue;
            if (wanted.major != online.major or wanted.minor != online.minor) continue;
            // Prefer newer versions
            if (compatible_version) |prev| {
                if (online.order(SemVer.parse(prev) catch unreachable).compare(.lte)) continue;
            }
            compatible_version = entry.version;
        } else {
            if (std.mem.eql(u8, version, entry.version)) return version;
            if (entry.alt_version) |v| if (std.mem.eql(u8, version, v)) return version;
        }
    }

    return compatible_version;
}

fn spawnZig(
    io: Io,
    versions_dir: Dir,
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
) !void {
    _ = versions_dir; // autofix
    var child = std.process.spawn(io, .{
        .argv = argv,
        .expand_arg0 = .no_expand,
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.PermissionDenied => blk: {
            try Dir.setFilePermissions(.cwd(), io, argv[0], .executable_file, .{});
            break :blk try std.process.spawn(io, .{
                .argv = argv,
                .expand_arg0 = .no_expand,
                .environ_map = environ_map,
            });
        },
        else => |e| return e,
    };
    _ = child.wait(io) catch {};

    // TODO: use this instead when std.Io implements it
    // switch (std.process.replacePath(io, versions_dir, .{
    //     .argv = argv,
    //     .expand_arg0 = .no_expand,
    //     .environ_map = environ_map,
    // })) {
    //     error.PermissionDenied => try Dir.setFilePermissions(versions_dir, io, argv[0], .executable_file, .{}),
    //     else => |err| return err,
    // }
    // return std.process.replacePath(io, versions_dir, .{
    //     .argv = argv,
    //     .expand_arg0 = .no_expand,
    //     .environ_map = environ_map,
    // });
}

pub fn main(init: std.process.Init) void {
    const gpa = init.gpa;
    const arena = init.arena;
    const io = init.io;

    var stdin_buf: [64]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &stdin_buf);
    var stdout_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const argv: [][]const u8 = @ptrCast(@constCast(init.minimal.args.toSlice(init.arena.allocator()) catch
        fatal("Out of memory while fetching args", .{})));

    const base_dir = files.openBaseDir(gpa, io, init.environ_map);
    defer base_dir.close(io);
    const versions_dir = base_dir.createDirPathOpen(io, files.VERSIONS_DIR, .{}) catch |err|
        fatal("Failed to create versions directory: {t}", .{err});
    defer versions_dir.close(io);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var index: ?[]const u8 = null;
    // TODO: check env vars to bypass prompts in non-interactive mode
    const zig_version, const installed = ver: {
        var master_ver_buf: [64]u8 = undefined;
        const v = detectZigVersion(gpa, io, &stdout.interface) orelse {
            index = files.getIndex(arena.allocator(), io, &client, base_dir) catch |err|
                fatal("Failed to get index: {t}", .{err});
            break :ver userSelectZigVersion(index.?, &stdin, &stdout.interface);
        };
        defer gpa.free(v);
        const version = arena.allocator().dupe(u8, v) catch fatal("Out of memory", .{});

        if (files.isZigVersionInstalled(io, versions_dir, version)) break :ver .{ version, true };
        if (files.installedMasterVersion(io, versions_dir, &master_ver_buf)) |mv| blk: {
            const wanted = std.SemanticVersion.parse(version) catch break :blk;
            const master = std.SemanticVersion.parse(mv) catch break :blk;
            if (wanted.major == master.major and wanted.minor == master.minor) {
                break :ver .{ "master", true };
            }
        }

        index = files.getIndex(arena.allocator(), io, &client, base_dir) catch |err|
            fatal("Failed to get index: {t}", .{err});
        const actual_version = getCompatibleZigVersion(index.?, version) orelse
            fatal("No available Zig version is compatible with {s}", .{version});
        if (std.mem.eql(u8, version, actual_version)) {
            stdout.interface.print(
                "Zig version {s} is not installed.\nInstall it? [Y/n] ",
                .{version},
            ) catch {};
        } else {
            stdout.interface.print(
                "Zig version {s} is not installed or available, but version {s} is avaliable online.\nInstall it? [Y/n] ",
                .{ version, actual_version },
            ) catch {};
        }
        stdout.interface.flush() catch {};

        const answer = stdin.interface.takeByte() catch |err|
            fatal("Failed to read input: {t}", .{switch (err) {
                error.EndOfStream => err,
                error.ReadFailed => stdin.err.?,
            }});
        if (answer != '\n') _ = stdin.interface.discardDelimiterInclusive('\n') catch {};
        if (!std.mem.containsAtLeastScalar(u8, "yY\n", answer, 1)) {
            stdout.interface.writeAll("Not installing Zig.\n") catch {};
            stdout.interface.flush() catch {};
            return std.process.cleanExit(io);
        }

        break :ver .{ actual_version, false };
    };
    if (!installed) {
        const tmp_dir = base_dir.createDirPathOpen(io, "tmp", .{}) catch |err|
            fatal("Failed to create temporary directory: {t}", .{err});
        defer tmp_dir.close(io);
        const mirrors = files.getMirrors(arena, io, &client, base_dir) catch |err|
            fatal("Failed to get mirrors list: {t}", .{err});
        // If the requested zig version was not installed, we must have searched
        // the index for a version to install, so the index cannot be null.
        installZig(
            &client,
            tmp_dir,
            versions_dir,
            mirrors,
            index.?,
            zig_version,
            &stdout.interface,
        );
    }

    var zig_path_buf: [Dir.max_name_bytes + 1 + files.ZIG_NAME.len]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&zig_path_buf);
    argv[0] = Dir.path.join(fba.allocator(), &.{ zig_version, files.ZIG_NAME }) catch |err|
        fatal("Failed to make path to Zig executable: {t}", .{err});
    // TODO: remove this when replacePath is implemented
    argv[0] = versions_dir.realPathFileAlloc(io, argv[0], arena.allocator()) catch |err| fatal("{t}", .{err});

    spawnZig(io, versions_dir, argv, init.environ_map) catch |err| fatal("Failed to run Zig: {t}", .{err});
    return std.process.cleanExit(io);
}
