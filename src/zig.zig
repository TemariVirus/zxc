const std = @import("std");
const builtin = @import("builtin");
const log = std.log.default;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const fatal = std.process.fatal;

const KeyReader = @import("KeyReader.zig");
const LockFile = @import("LockFile.zig");
const files = @import("files.zig");
const fs = @import("fs.zig");
const http = @import("http.zig");
const term = @import("term.zig");

const SAFETY_ON = switch (builtin.optimize) {
    .debug, .safe => true,
    .fast, .small => false,
};

const EnvVars = struct {
    pub const FORCE_ZIG_VERSION = "ZXC_FORCE_ZIG_VERSION";
    // Only used when non-interactive
    pub const ALWAYS_INSTALL = "ZXC_ALWAYS_INSTALL";

    pub fn getNonEmpty(environ: *const EnvMap, key: []const u8) ?[]const u8 {
        const value = environ.get(key) orelse return null;
        return if (value.len == 0) null else value;
    }
};

pub const WantedZigInfo = struct {
    installed: bool,
    used_user_input: bool,
    wanted_version: []const u8,
    resolved_version: []const u8,

    pub fn deinit(self: WantedZigInfo, allocator: Allocator) void {
        allocator.free(self.wanted_version);
        allocator.free(self.resolved_version);
    }
};

/// Installs the zig version into a subfolder in `versions_path`.
/// The comparessed tarball is temporarily stored in `tmp_dir`.
fn installZig(
    client: *std.http.Client,
    tmp_dir: Dir,
    versions_path: []const u8,
    mirrors: []const []const u8,
    index: []const u8,
    version: []const u8,
    stdout: *Io.Writer,
) void {
    const allocator = client.allocator;
    const io = client.io;

    const lock = LockFile.lock(allocator, io, tmp_dir, version) catch |err|
        fatal("Failed to create file lock: {t}", .{err});
    defer lock.unlock(allocator, io);
    if (files.isNewestVersionInstalled(io, index, versions_path, version) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
    }) {
        return; // Someone else installed it for us
    }

    log.info("Fetching Zig version {s}...", .{version});

    const versions_dir = Dir.createDirPathOpen(.cwd(), io, versions_path, .{}) catch |err|
        fatal("Failed to create versions directory: {t}", .{err});
    defer versions_dir.close(io);
    const work_dir = lock.getLockedDir(io, .{}) catch |err|
        fatal("Failed to create temporary directory: {t}", .{err});
    defer {
        work_dir.close(io);
        log.info("Cleaning up extracted tarball...", .{});
        tmp_dir.deleteFile(io, version) catch {};
    }

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

    const archive_file = work_dir.createFile(io, tarball_info.name, .{ .read = true }) catch |err|
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
    const extracted_name = files.extractZigTarball(allocator, io, archive_file, tarball_info.name, work_dir) catch |err|
        fatal("Failed to extract tarball: {t}", .{err});
    fs.forceRename(work_dir, extracted_name, versions_dir, version, io) catch |err|
        fatal("Failed to install extracted tarball: {t}", .{err});

    log.info("Successfully installed zig {s}!", .{version});
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
    versions_path: []const u8,
    stdout: *Io.Writer,
) struct { []const u8, bool } {
    const MAX_MENU_HEIGHT = 10;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const versions = files.getAllVersions(arena.allocator(), io, versions_path, index) catch |err| switch (err) {
        error.OutOfMemory => fatal("Out of memory.", .{}),
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        else => fatal("Unable to open versions directory: {t}", .{err}),
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
            .k, .w, .up => choice = (choice + versions.len - 1) % versions.len,
            .j, .s, .down => choice = (choice + 1) % versions.len,
            .enter => break,
            .sigint => {
                cleanupVersionMenu(stdout, kr);
                std.process.exit(130); // Typical for dying by SIGINT
            },
        }
    }

    const chosen = allocator.dupe(u8, versions[choice].name) catch {
        cleanupVersionMenu(stdout, kr);
        fatal("Out of memory.", .{});
    };
    errdefer allocator.free(chosen);
    return .{ chosen, versions[choice].installed };
}

pub fn getWantedZigInfo(
    allocator: Allocator,
    client: *std.http.Client,
    env_map: *const EnvMap,
    stdout: *Io.Writer,
    enable_user_input: bool,
) WantedZigInfo {
    const io = client.io;

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, env_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    const base_dir = Dir.openDirAbsolute(io, base_path, .{}) catch |err|
        fatal("Failed to open base directory: {t}", .{err});
    defer base_dir.close(io);
    const versions_path = fs.joinPathsInPlace(&path_buf, base_path.len, &.{files.VERSIONS_DIR}) catch
        fatal("Out of memory.", .{});

    var installed = false;
    var used_user_input = false;
    var use_exact_version = false;
    const wanted_version = ver: {
        if (EnvVars.getNonEmpty(env_map, EnvVars.FORCE_ZIG_VERSION)) |v| {
            installed = files.isZigVersionInstalled(io, versions_path, v);
            use_exact_version = true;
            break :ver allocator.dupe(u8, v) catch fatal("Out of memory.", .{});
        }

        if (files.detectZigVersionFromCwd(allocator, io) catch |err| blk: switch (err) {
            error.FileNotFound => {
                log.info("No build.zig.zon found.", .{});
                break :blk null;
            },
            error.ParseZon => fatal(
                \\Failed to detect Zig version from build.zig.zon.
                \\       Ensure the `minimum_zig_version` field is a valid semantic version.
            , .{}),
            else => fatal("Failed to read build.zig.zon: {t}", .{err}),
        }) |v| break :ver v;

        if (!term.isInteractive()) {
            fatal(
                "Set the envivonment variable {s} or run `zig` to select a version first.",
                .{EnvVars.FORCE_ZIG_VERSION},
            );
        }

        if (enable_user_input) {
            const index = files.getIndex(allocator, client, base_dir) catch |err|
                fatal("Failed to get index: {t}", .{err});
            defer allocator.free(index);
            const v, installed = selectVersionMenu(allocator, io, index, versions_path, stdout);
            used_user_input = true;
            use_exact_version = true;
            // TODO: add choice to imaginary build.zig.zon
            break :ver v;
        }
        std.process.exit(1);
    };
    errdefer allocator.free(wanted_version);

    const resolved_version = if (use_exact_version)
        allocator.dupe(u8, wanted_version) catch fatal("Out of memory.", .{})
    else if (files.resolveFromInstalledZigVersion(io, versions_path, wanted_version)) |v| ver: {
        installed = true;
        break :ver allocator.dupe(u8, v) catch fatal("Out of memory.", .{});
    } else ver: {
        const index = files.getIndex(allocator, client, base_dir) catch |err|
            fatal("Failed to get index: {t}", .{err});
        defer allocator.free(index);
        const v = files.getCompatibleZigVersion(index, wanted_version) catch |err| switch (err) {
            error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        } orelse fatal("No available Zig version is compatible with {s}", .{wanted_version});
        installed = files.isZigVersionInstalled(io, versions_path, v);
        break :ver allocator.dupe(u8, v) catch fatal("Out of memory.", .{});
    };
    errdefer allocator.free(resolved_version);

    return WantedZigInfo{
        .installed = installed,
        .used_user_input = used_user_input,
        .wanted_version = wanted_version,
        .resolved_version = resolved_version,
    };
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
    argv: []const []const u8,
    environ_map: *const EnvMap,
) !void {
    if (SAFETY_ON) {
        // Spawn a new process instead of replacing, so that we can exit normally and collect errors
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
        return;
    }

    switch (std.process.replace(io, .{
        .argv = argv,
        .expand_arg0 = .no_expand,
        .environ_map = environ_map,
    })) {
        error.PermissionDenied => try Dir.cwd().setFilePermissions(io, argv[0], .executable_file, .{}),
        else => |err| return err,
    }
    return std.process.replace(io, .{
        .argv = argv,
        .expand_arg0 = .no_expand,
        .environ_map = environ_map,
    });
}

pub fn main(init: std.process.Init.Minimal) void {
    var safe_gpa = if (SAFETY_ON)
        std.heap.SafeAllocator.init(std.heap.page_allocator, .{
            .stack_trace_frames = 7,
            .check_write_after_free = true,
        })
    else {};
    defer _ = if (SAFETY_ON) safe_gpa.deinit();
    const gpa = if (SAFETY_ON) safe_gpa.allocator() else std.heap.smp_allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var threaded: Io.Threaded = .init(gpa, .{
        .stack_size = 512 * 1024,
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const environ_map = init.environ.createMap(arena.allocator()) catch |err|
        fatal("Failed to create env var map: {t}", .{err});
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var stdin_buf: [64]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
    var stdout_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const argv: [][]const u8 = @ptrCast(@constCast(init.args.toSlice(arena.allocator()) catch
        fatal("Out of memory while parsing args.", .{})));

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, &environ_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    const versions_path = fs.joinPathsInPlace(&path_buf, base_path.len, &.{files.VERSIONS_DIR}) catch
        fatal("Out of memory.", .{});
    const base_dir = files.openBaseDir(io, &environ_map);
    defer base_dir.close(io);

    const info = getWantedZigInfo(gpa, &client, &environ_map, &stdout.interface, true);
    defer info.deinit(gpa);

    var confirmed_install = info.used_user_input;
    if (!info.installed and !confirmed_install) {
        confirmed_install = if (term.isInteractive())
            confirmInstallPrompt(
                info.wanted_version,
                info.resolved_version,
                &stdin.interface,
                &stdout.interface,
            ) catch |err| fatal("Failed to read input: {t}", .{switch (err) {
                error.EndOfStream => err,
                error.ReadFailed => stdin.err.?,
            }})
        else if (EnvVars.getNonEmpty(&environ_map, EnvVars.ALWAYS_INSTALL) == null)
            fatal(
                \\Zig version {s} is not installed.
                \\Non-interactive mode requires the environment variable {s} to be non-empty to automatically install new versions.
            ,
                .{ info.resolved_version, EnvVars.ALWAYS_INSTALL },
            )
        else
            true;

        if (!confirmed_install) {
            stdout.interface.writeAll("Not installing Zig.\n") catch {};
            stdout.interface.flush() catch {};
            return std.process.cleanExit(io);
        }
    }

    if (!info.installed) {
        if (!LockFile.isValidKey(info.resolved_version)) {
            fatal("Zig version cannot start with 'lock.'", .{});
        }

        const tmp_dir = files.openTmpDir(io, base_dir) catch |err|
            fatal("Failed to create temporary directory: {t}", .{err});
        defer tmp_dir.close(io);
        const index = files.getIndex(arena.allocator(), &client, base_dir) catch |err|
            fatal("Failed to get index: {t}", .{err});
        defer arena.allocator().free(index);

        const mirrors = files.getMirrors(&arena, &client, base_dir) catch |err| switch (err) {
            error.NoMirrors => @constCast(&.{}),
            else => fatal("Failed to get mirrors list: {t}", .{err}),
        };
        installZig(
            &client,
            tmp_dir,
            versions_path,
            mirrors,
            index,
            info.resolved_version,
            &stdout.interface,
        );
        LockFile.cleanUpUnlocked(io, tmp_dir);
    }

    argv[0] = fs.joinPathsInPlace(
        &path_buf,
        versions_path.len,
        &.{ info.resolved_version, files.ZIG_NAME },
    ) catch |err| fatal("Failed to make path to Zig executable: {t}", .{err});
    spawnZig(io, argv, &environ_map) catch |err| fatal("Failed to run Zig: {t}", .{err});
    return std.process.cleanExit(io);
}
