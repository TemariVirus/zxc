const std = @import("std");
const builtin = @import("builtin");
const log = std.log.default;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const Io = std.Io;
const Rng = std.Random.ChaCha;
const fatal = std.process.fatal;

const KeyReader = @import("KeyReader.zig");
const LockFile = @import("LockFile.zig");
const files = @import("files.zig");
const http = @import("http.zig");
const term = @import("term.zig");

const EnvVars = struct {
    pub const DEFAULT_ZIG_VERSION = "ZXC_DEFAULT_ZIG_VERSION";
    pub const ALWAYS_INSTALL = "ZXC_ALWAYS_INSTALL";

    pub fn getNonEmpty(environ: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
        const value = environ.get(key) orelse return null;
        return if (value.len == 0) null else value;
    }
};

fn keyFromFilename(name: []const u8) []const u8 {
    // Lock file
    if (std.mem.cutSuffix(u8, name, ".lock")) |key| return key;
    const stem =
        // Archive file
        std.mem.cutSuffix(u8, name, ".tar.xz") orelse
        std.mem.cutSuffix(u8, name, ".zip") orelse
        // Extracted directory
        name;
    const target1 = std.fmt.comptimePrint("zig-{t}-{t}-", .{ builtin.cpu.arch, builtin.os.tag }); // 0.14.1 and above
    const target2 = std.fmt.comptimePrint("zig-{t}-{t}-", .{ builtin.os.tag, builtin.cpu.arch }); // 0.14.0 and below
    const version =
        std.mem.cutPrefix(u8, stem, target1) orelse
        std.mem.cutPrefix(u8, stem, target2) orelse
        // Unknown version
        return "master";
    // If a custom version doesn't follow semver, returning "master" ensures that
    // locking still works, at the cost of overzealous locking.
    const semver = std.SemanticVersion.parse(version) catch return "master";
    // master should have both `build` and/or `pre` fields set.
    // Unfortunately this is also the case for Mach's nominated Zig versions,
    // and we have no way of infering "2026.4.10-mach" from "0.16.0-dev.3142+5ccfeb926"
    // without scanning through Mach's index.
    // However that is a bandaid solution that fails if other indexes share those versions.
    // Thus, we always return "master" to play safe.
    if (semver.build != null or semver.pre != null) return "master";
    return version;
}

/// `tmp_dir` must be opened with `.iterate = true`.
fn cleanUpTmpDir(io: Io, tmp_dir: Dir) void {
    var fba_buf: [Dir.max_name_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const allocator = fba.allocator();

    var iter = tmp_dir.iterate();
    while (iter.next(io) catch return) |entry| {
        switch (entry.kind) {
            .directory, .file => {},
            else => continue,
        }

        const key = keyFromFilename(entry.name);
        const lock = LockFile.tryLock(allocator, io, tmp_dir, key) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
        defer lock.unlock(allocator, io);
        _ = switch (entry.kind) {
            .directory => tmp_dir.deleteTree(io, entry.name),
            .file => tmp_dir.deleteFile(io, entry.name),
            else => unreachable,
        } catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
    }
}

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
    const allocator = client.allocator;
    const io = client.io;

    const lock = LockFile.lock(allocator, io, tmp_dir, version) catch |err|
        fatal("Failed to create file lock: {t}", .{err});
    defer lock.unlock(allocator, io);
    if (files.isNewestVersionInstalled(io, index, versions_dir, version) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
    }) {
        return;
    }

    log.info("Fetching Zig version {s}...", .{version});

    var rng: Rng = rng: {
        var seed: [Rng.secret_seed_length]u8 = undefined;
        io.random(&seed);
        break :rng .init(seed);
    };
    rng.random().shuffle([]const u8, mirrors);

    const tarball_info = files.getTarballInfo(index, version, files.SELF_TARGET) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
    } orelse {
        fatal("No tarball exists for version {s} on target {s}", .{ version, files.SELF_TARGET });
    };
    _ = files.ArchiveFormat.fromFileName(tarball_info.name) orelse
        fatal("Unsupported archive format: {s}", .{Dir.path.extension(tarball_info.name)});
    // Prevent path traversal
    for (tarball_info.name) |c| {
        if (Dir.path.isSep(c)) fatal("Invalid tarball name: {s}\n", .{tarball_info.name});
    }

    const archive_file = tmp_dir.createFile(io, tarball_info.name, .{ .read = true }) catch |err|
        fatal("Failed to create tarball file: {t}", .{err});
    defer archive_file.close(io);
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

    log.info("Extracting tarball...", .{});
    files.extractZigTarball(allocator, io, versions_dir, tmp_dir, archive_file, tarball_info.name, version) catch |err|
        fatal("Failed to extract tarball: {t}", .{err});

    log.info("Successfully installed zig {s}!", .{version});

    log.info("Cleaning up extracted tarball...", .{});
    tmp_dir.deleteFile(io, tarball_info.name) catch {};
    cleanUpTmpDir(io, tmp_dir);
}

/// Returns the zig version from `zon_path`, or null if the path does not exist.
/// If the file at `zon_path` does not store the zig version, `error.ParseZon` is returned.
fn getZigVersionFromBuildZigZon(
    allocator: Allocator,
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

fn cleanupVersionMenu(stdout: *Io.Writer, kr: KeyReader) void {
    term.setCursorVisibility(stdout, true) catch {};
    term.previousLine(stdout, 2) catch {}; // Instruction text takes up 2 lines
    term.erase(stdout, .after_cursor) catch {};
    stdout.flush() catch {};
    kr.deinit();
}

fn selectVersionMenu(
    allocator: Allocator,
    io: Io,
    index: []const u8,
    base_dir: Dir,
    stdout: *Io.Writer,
) struct { []const u8, bool } {
    const MAX_MENU_HEIGHT = 10;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const versions = files.getAllVersions(arena.allocator(), io, base_dir, index) catch |err| switch (err) {
        error.OutOfMemory => fatal("Out of memory", .{}),
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        else => fatal("Unable to open versions folder: {t}", .{err}),
    };
    std.sort.pdq(files.ZigVersion, versions, {}, files.ZigVersion.greaterThan);

    const kr = KeyReader.init() catch |err| fatal("Unable to set up CLI menu: {t}", .{err});
    defer cleanupVersionMenu(stdout, kr);

    term.setCursorVisibility(stdout, false) catch {};
    stdout.writeAll(
        \\Use arrow keys to move, and press ENTER to confirm.
        \\Select Zig version:
        \\
    ) catch {};
    const menu_height = @min(MAX_MENU_HEIGHT, versions.len);
    var choice: usize = 0;
    while (true) {
        const top_margin = (menu_height / 2);
        const bottom_margin = ((menu_height + 1) / 2);
        const menu_start, const menu_end = if (choice < top_margin)
            .{ 0, menu_height }
        else if (choice > versions.len - bottom_margin)
            .{ versions.len - menu_height, versions.len }
        else
            .{ choice - top_margin, choice + bottom_margin };

        term.erase(stdout, .after_cursor) catch {};
        for (menu_start..menu_end) |i| {
            if (i == choice) {
                stdout.writeAll("> ") catch {};
            } else {
                stdout.writeAll("  ") catch {};
            }
            stdout.print("{f}\n", .{versions[i]}) catch {};
        }
        if (menu_end < versions.len) {
            stdout.writeAll("  ...\n") catch {};
            term.previousLine(stdout, 1) catch {};
        }
        term.previousLine(stdout, menu_height) catch {};
        stdout.flush() catch {};

        const key = kr.read(io) catch |err| {
            cleanupVersionMenu(stdout, kr);
            fatal("Unable to read user input: {t}", .{err});
        };
        switch (key) {
            .up => choice = (choice + versions.len - 1) % versions.len,
            .down => choice = (choice + 1) % versions.len,
            .enter => break,
            .sigint => {
                cleanupVersionMenu(stdout, kr);
                std.process.exit(130); // Typical for dying by SIGINT
            },
        }
    }

    const chosen = allocator.dupe(u8, versions[choice].name) catch {
        cleanupVersionMenu(stdout, kr);
        fatal("Out of memory", .{});
    };
    errdefer allocator.free(chosen);
    return .{ chosen, versions[choice].installed };
}

/// Tries to detect the required zig version based on the current working directory.
fn detectZigVersion(allocator: Allocator, io: Io) ?[]const u8 {
    const filename = "build.zig.zon";

    // This will usually succeed, allowing us to skip a syscall to get the current path
    if (getZigVersionFromBuildZigZon(allocator, io, filename) catch |err| switch (err) {
        error.ParseZon => {
            log.warn("Failed to detect Zig version from build.zig.zon.", .{});
            return null;
        },
        else => fatal("Failed to read build.zig.zon: {t}", .{err}),
    }) |ver| return ver;

    const path_buf = allocator.alloc(u8, Dir.max_path_bytes + 1 + filename.len) catch fatal("Out of memory", .{});
    defer allocator.free(path_buf);
    const path = path_buf[0 .. std.process.currentPath(io, path_buf) catch |err|
        fatal("Unable to get current working directory: {t}", .{err})];
    if (path.len > Dir.max_path_bytes) fatal("Current working directory name was too long.", .{});

    var iter = Dir.path.componentIterator(path);
    _ = iter.last() orelse unreachable;
    while (iter.previous()) |dir| {
        @memcpy(path_buf[dir.path.len + 1 ..][0..filename.len], filename);
        const zon_path = path_buf[0 .. dir.path.len + 1 + filename.len];
        if (getZigVersionFromBuildZigZon(allocator, io, zon_path) catch |err| switch (err) {
            error.ParseZon => {
                log.warn("Failed to detect Zig version from build.zig.zon.", .{});
                return null;
            },
            else => fatal("Failed to read build.zig.zon: {t}", .{err}),
        }) |ver| return ver;
    } else blk: {
        const dir = iter.root() orelse break :blk;
        @memcpy(path_buf[dir.len..][0..filename.len], filename);
        const zon_path = path_buf[0 .. dir.len + filename.len];
        if (getZigVersionFromBuildZigZon(allocator, io, zon_path) catch |err| switch (err) {
            error.ParseZon => {
                log.warn("Failed to detect Zig version from build.zig.zon.", .{});
                return null;
            },
            else => fatal("Failed to read build.zig.zon: {t}", .{err}),
        }) |ver| return ver;
    }

    log.info("No build.zig.zon found.", .{});
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
            const online = SemVer.parse(entry.version orelse entry.name) catch continue;
            if (wanted.major != online.major or wanted.minor != online.minor) continue;
            // Prefer newer versions
            if (compatible_version) |prev| {
                if (online.order(SemVer.parse(prev) catch unreachable).compare(.lte)) continue;
            }
            compatible_version = entry.name;
        } else {
            if (std.mem.eql(u8, version, entry.name)) return version;
            if (entry.version) |v| if (std.mem.eql(u8, version, v)) return version;
        }
    }

    return compatible_version;
}

fn confirmInstallPrompt(
    wanted_version: []const u8,
    actual_version: []const u8,
    stdin: *Io.Reader,
    stdout: *Io.Writer,
) !bool {
    if (std.mem.eql(u8, wanted_version, actual_version)) {
        stdout.print(
            "Zig version {s} is not installed.\nInstall it? [Y/n] ",
            .{wanted_version},
        ) catch {};
    } else {
        stdout.print(
            "Zig version {s} is not installed or available, but version {s} is avaliable online.\nInstall it? [Y/n] ",
            .{ wanted_version, actual_version },
        ) catch {};
    }
    stdout.flush() catch {};

    const answer = try stdin.takeByte();
    if (answer != '\n') _ = stdin.discardDelimiterInclusive('\n') catch {};
    return std.mem.containsAtLeastScalar(u8, "yY\n", answer, 1);
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
    var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
    var stdout_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
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
    var tmp_dir: ?Dir = null;
    defer if (tmp_dir) |d| d.close(io);
    const zig_version, const installed = ver: {
        var master_ver_buf: [64]u8 = undefined;
        const version = if (detectZigVersion(gpa, io)) |v| blk: {
            defer gpa.free(v);
            break :blk arena.allocator().dupe(u8, v) catch fatal("Out of memory", .{});
        } else blk: {
            index = files.getIndex(arena.allocator(), &client, base_dir) catch |err|
                fatal("Failed to get index: {t}", .{err});

            // Clean up while waiting for user input
            tmp_dir = files.openTmpDir(io, base_dir) catch null;
            var cleanup_task = if (tmp_dir) |d| io.async(cleanUpTmpDir, .{ io, d }) else null;
            defer if (cleanup_task) |*t| t.cancel(io); // Don't bother waiting for it to complete
            if (!(term.isatty(stdin.file.handle) catch false)) {
                break :blk EnvVars.getNonEmpty(init.environ_map, EnvVars.DEFAULT_ZIG_VERSION) orelse
                    fatal(
                        "Non-interactive mode requires the environment variable {s} to be set when the Zig version cannot be detected.",
                        .{EnvVars.DEFAULT_ZIG_VERSION},
                    );
            }
            const v, const installed = selectVersionMenu(gpa, io, index.?, base_dir, &stdout.interface);
            defer gpa.free(v);
            const version = arena.allocator().dupe(u8, v) catch fatal("Out of memory", .{});
            break :ver .{ version, installed };
        };

        if (files.isZigVersionInstalled(io, versions_dir, version)) break :ver .{ version, true };
        if (files.installedMasterVersion(io, versions_dir, &master_ver_buf)) |mv| blk: {
            const wanted = std.SemanticVersion.parse(version) catch break :blk;
            const master = std.SemanticVersion.parse(mv) catch break :blk;
            if (wanted.major == master.major and wanted.minor == master.minor) {
                break :ver .{ "master", true };
            }
        }

        index = files.getIndex(arena.allocator(), &client, base_dir) catch |err|
            fatal("Failed to get index: {t}", .{err});
        const actual_version = getCompatibleZigVersion(index.?, version) orelse
            fatal("No available Zig version is compatible with {s}", .{version});

        // Clean up while waiting for user input
        tmp_dir = files.openTmpDir(io, base_dir) catch null;
        var cleanup_task = if (tmp_dir) |d| io.async(cleanUpTmpDir, .{ io, d }) else null;
        defer if (cleanup_task) |*t| t.cancel(io); // Don't bother waiting for it to complete
        const confirmed = if (term.isatty(stdin.file.handle) catch false)
            confirmInstallPrompt(
                version,
                actual_version,
                &stdin.interface,
                &stdout.interface,
            ) catch |err| fatal("Failed to read input: {t}", .{switch (err) {
                error.EndOfStream => err,
                error.ReadFailed => stdin.err.?,
            }})
        else if (EnvVars.getNonEmpty(init.environ_map, EnvVars.ALWAYS_INSTALL) == null)
            fatal(
                \\Zig version {s} is not installed.
                \\Non-interactive mode requires the environment variable {s} to be non-empty to automatically install new versions.
            ,
                .{ version, EnvVars.ALWAYS_INSTALL },
            )
        else
            true;

        if (!confirmed) {
            stdout.interface.writeAll("Not installing Zig.\n") catch {};
            stdout.interface.flush() catch {};
            return std.process.cleanExit(io);
        }

        break :ver .{ actual_version, false };
    };
    if (!installed) {
        if (tmp_dir == null) {
            tmp_dir = files.openTmpDir(io, base_dir) catch |err|
                fatal("Failed to create temporary directory: {t}", .{err});
        }
        const mirrors = files.getMirrors(arena, &client, base_dir) catch |err| switch (err) {
            error.NoMirrors => @constCast(&.{}),
            else => fatal("Failed to get mirrors list: {t}", .{err}),
        };
        // If the requested zig version was not installed, we must have searched
        // the index for a version to install, so the index cannot be null.
        installZig(
            &client,
            tmp_dir.?,
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
