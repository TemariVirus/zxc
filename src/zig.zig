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
const pv_store = @import("path_version_store.zig");
const term = @import("term.zig");

const SAFETY_ON = switch (builtin.optimize) {
    .debug, .safe => true,
    .fast, .small => false,
};

const EnvVars = struct {
    pub const FORCE_ZIG_VERSION = "ZXC_FORCE_ZIG_VERSION";
    // Only used when non-interactive
    pub const ALWAYS_INSTALL = "ZXC_ALWAYS_INSTALL";

    pub fn getNonEmpty(env_map: *const EnvMap, key: []const u8) ?[]const u8 {
        const value = env_map.get(key) orelse return null;
        return if (value.len == 0) null else value;
    }
};

const WantedZig = struct {
    version: files.Version,
    source: enum {
        force,
        build_zig_zon,
        pv_store,
    },
};

pub const CurrentZigInfo = struct {
    installed: bool,
    used_user_input: bool,
    wanted: files.Version,
    resolved: files.Version,

    pub fn deinit(self: CurrentZigInfo, allocator: Allocator) void {
        allocator.free(self.wanted.name());
        allocator.free(self.resolved.name());
    }
};

pub const UserInputArgs = struct {
    stdout: *Io.Writer,
};

/// Installs the zig version. The comparessed tarball is temporarily stored in `tmp_dir`.
fn installZig(
    g: *files.Globals,
    tmp_dir: Dir,
    mirrors: []const []const u8,
    version: files.Version,
    stdout: *Io.Writer,
) void {
    const allocator = g.getScratchAllocator();
    const io = g.getIo();

    const versions_dir = g.getBaseDir().createDirPathOpen(io, files.VERSIONS_DIR, .{}) catch |err|
        fatal("Failed to create versions directory: {t}", .{err});
    defer versions_dir.close(io);

    const lock = LockFile.lock(allocator, io, tmp_dir, version.name()) catch |err|
        fatal("Failed to create file lock: {t}", .{err});
    defer lock.unlock(allocator, io);
    if (files.isNewestVersionInstalled(io, g.env_map, versions_dir, g.getIndex(), version) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
    }) {
        return; // Someone else installed it for us
    }

    log.info("Fetching Zig version {s}...", .{version.name()});
    const work_dir = lock.getLockedDir(io, .{}) catch |err|
        fatal("Failed to create temporary directory: {t}", .{err});
    defer work_dir.close(io);

    const tarball_info = files.getTarballInfo(g.getIndex(), version.name(), files.SELF_TARGET) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
    } orelse {
        fatal("No tarball exists for version {s} on target {s}", .{ version.name(), files.SELF_TARGET });
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
        http.downloadZig(&g.client, mirror, tarball_info, archive_file, stdout) catch continue;
        break;
    } else {
        log.warn("Failed to download zig from all mirrors. Trying ziglang.org as fallback...", .{});
        http.downloadZig(&g.client, tarball_info.fallback_url, tarball_info, archive_file, stdout) catch
            fatal("Exhausted all sources. Exiting.", .{});
    }

    log.info("Extracting tarball...", .{});
    const extracted_name = files.extractZigTarball(allocator, io, archive_file, tarball_info.name, work_dir) catch |err|
        fatal("Failed to extract tarball: {t}", .{err});
    fs.forceRename(work_dir, extracted_name, versions_dir, version.name(), io) catch |err|
        fatal("Failed to install extracted tarball: {t}", .{err});

    log.info("Successfully installed zig {s}!", .{version.name()});
}

fn cleanupVersionMenu(stdout: *Io.Writer, kr: KeyReader) void {
    term.setCursorVisibility(stdout, true) catch {};
    term.previousLine(stdout, 2) catch {}; // Instruction text takes up 2 lines
    term.erase(stdout, .after_cursor) catch {};
    stdout.flush() catch {};
    kr.deinit();
}

fn menuInner(
    allocator: Allocator,
    g: *files.Globals,
    kr: *KeyReader,
    versions: []const files.ZigVersion,
    stdout: *Io.Writer,
) !CurrentZigInfo {
    const MAX_MENU_HEIGHT = 10;
    const io = g.getIo();

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

        const key = try kr.read(io);
        switch (key) {
            .k, .w, .up => choice = (choice + versions.len - 1) % versions.len,
            .j, .s, .down => choice = (choice + 1) % versions.len,
            .enter => break,
            .sigint => return error.ReceivedSigint,
        }
    }

    const chosen = try allocator.dupe(u8, versions[choice].name);
    errdefer allocator.free(chosen);
    const chosen2 = try allocator.dupe(u8, chosen);
    errdefer allocator.free(chosen2);
    return .{
        .installed = versions[choice].installed,
        .used_user_input = true,
        // Must be seperate allocations
        .wanted = try .parse(chosen),
        .resolved = try .parse(chosen2),
    };
}

/// Returns the selected version as both `wanted` and `resolved`.
fn selectVersionMenu(
    allocator: Allocator,
    g: *files.Globals,
    stdout: *Io.Writer,
) CurrentZigInfo {
    const io = g.getIo();

    var arena: std.heap.ArenaAllocator = .init(g.getScratchAllocator());
    defer arena.deinit();
    const versions = files.getAllVersions(
        arena.allocator(),
        io,
        g.env_map,
        g.getBaseDir(),
        g.getIndex(),
    ) catch |err| switch (err) {
        error.OutOfMemory => fatal("Out of memory.", .{}),
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        else => fatal("Unable to open versions directory: {t}", .{err}),
    };
    std.sort.pdq(files.ZigVersion, versions, {}, files.ZigVersion.greaterThan);

    var kr = KeyReader.init() catch |err| fatal("Unable to set up CLI menu: {t}", .{err});
    defer cleanupVersionMenu(stdout, kr);

    return menuInner(allocator, g, &kr, versions, stdout) catch |err| {
        cleanupVersionMenu(stdout, kr);
        switch (err) {
            error.ReadFailed => fatal("Unable to read user input: {t}", .{kr.getErr()}),
            error.OutOfMemory => fatal("Out of memory.", .{}),
            error.InvalidVersionName => fatal("Zig version cannot start with 'lock.'", .{}),
            // Typical for dying by SIGINT
            error.ReceivedSigint => std.process.exit(130),
        }
    };
}

fn getWantedZig(allocator: Allocator, g: *files.Globals) ?WantedZig {
    const io = g.getIo();

    if (EnvVars.getNonEmpty(g.env_map, EnvVars.FORCE_ZIG_VERSION)) |v| {
        const version_string = allocator.dupe(u8, v) catch fatal("Out of memory.", .{});
        return .{
            .version = .parseOrCrash(version_string),
            .source = .force,
        };
    }

    if (files.getZigVersionFromAnyZon(allocator, io)) |v| {
        return .{
            .version = .{ .semver = v },
            .source = .build_zig_zon,
        };
    } else |err| switch (err) {
        error.FileNotFound => log.info("No build.zig.zon found.", .{}),
        error.ParseZon => fatal(
            // Extra space to line up the 2nd line
            \\Failed to detect Zig version from build.zig.zon.
            \\       Ensure the `minimum_zig_version` field is a valid semantic version.
        , .{}),
        else => fatal("Failed to read build.zig.zon: {t}", .{err}),
    }

    if (pv_store.getVersionCwd(allocator, io, g.getBaseDir())) |maybe_ver| {
        if (maybe_ver) |v| {
            return .{
                .version = .{ .semver = v },
                .source = .pv_store,
            };
        }
    } else |err| {
        log.err("Failed to get previously selected version: {t}", .{err});
    }

    if (!term.isInteractive()) {
        fatal(
            "Set the envivonment variable {s} or run `zig` to select a version first.",
            .{EnvVars.FORCE_ZIG_VERSION},
        );
    }

    return null;
}

/// Returns the resolved Zig version name and whether it is installed.
fn resolveZigVersion(
    allocator: Allocator,
    g: *files.Globals,
    wanted: WantedZig,
    /// Enabled if not `null`
    enable_user_input: ?UserInputArgs,
) ?struct { []const u8, bool } {
    const io = g.getIo();

    const versions_dir = g.getBaseDir().openDir(io, files.VERSIONS_DIR, .{}) catch |err|
        fatal("Failed to open versions directory: {t}", .{err});
    defer versions_dir.close(io);

    if (files.resolveFromInstalledZigVersion(
        io,
        g.env_map,
        versions_dir,
        wanted.version,
    )) |v| {
        return .{
            allocator.dupe(u8, v) catch fatal("Out of memory.", .{}),
            true,
        };
    }

    const v = files.getCompatibleZigVersion(g.getIndex(), wanted.version) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
    } orelse {
        switch (wanted.source) {
            .pv_store => if (enable_user_input) |_| return null,
            .build_zig_zon => {},
            .force => unreachable,
        }
        fatal("No available Zig version is compatible with {s}", .{wanted.version.name()});
    };

    return .{
        allocator.dupe(u8, v) catch fatal("Out of memory.", .{}),
        files.isZigVersionInstalled(io, versions_dir, v),
    };
}

pub fn getCurrentZigInfo(
    allocator: Allocator,
    g: *files.Globals,
    /// Enabled if not `null`
    enable_user_input: ?UserInputArgs,
) CurrentZigInfo {
    const wanted = getWantedZig(allocator, g) orelse {
        if (enable_user_input) |args| {
            return selectVersionMenu(allocator, g, args.stdout);
        }
        std.process.exit(1);
    };
    errdefer allocator.free(wanted.version.name());

    const resolved_version, const installed = resolveZigVersion(
        allocator,
        g,
        wanted,
        enable_user_input,
    ) orelse {
        if (enable_user_input) |args| {
            return selectVersionMenu(allocator, g, args.stdout);
        }
        unreachable;
    };
    errdefer allocator.free(resolved_version);
    const resolved: files.Version = .parseOrCrash(resolved_version);

    return CurrentZigInfo{
        .installed = installed,
        .used_user_input = false,
        .wanted = wanted.version,
        .resolved = resolved,
    };
}

fn confirmInstallPrompt(
    index: []const u8,
    wanted_name: []const u8,
    resolved_name: []const u8,
    stdin: *Io.Reader,
    stdout: *Io.Writer,
) !bool {
    if (std.mem.eql(u8, wanted_name, resolved_name)) {
        stdout.print("Zig version {s} is not installed.\n", .{wanted_name}) catch {};
    } else {
        stdout.print(
            "Zig version {s} is not installed or available, but version {s} ",
            .{ wanted_name, resolved_name },
        ) catch {};
        if (files.indexVersion(index, resolved_name) catch null) |v| {
            if (!std.mem.eql(u8, resolved_name, v)) {
                stdout.print("({s}) ", .{v}) catch {};
            }
        }
        stdout.writeAll("is avaliable online.\n") catch {};
    }
    stdout.writeAll("Install it? [Y/n] ") catch {};
    stdout.flush() catch {};

    const answer = try stdin.takeByte();
    if (answer != '\n') _ = stdin.discardDelimiterInclusive('\n') catch {};
    return std.mem.containsAtLeastScalar(u8, "yY\n", answer, 1);
}

fn replaceWithZig(
    io: Io,
    argv: []const []const u8,
    env_map: *const EnvMap,
) !void {
    switch (std.process.replace(io, .{
        .argv = argv,
        .expand_arg0 = .no_expand,
        .environ_map = env_map,
    })) {
        error.PermissionDenied => try Dir.cwd().setFilePermissions(io, argv[0], .executable_file, .{}),
        else => |err| return err,
    }
    return std.process.replace(io, .{
        .argv = argv,
        .expand_arg0 = .no_expand,
        .environ_map = env_map,
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
    const env_map = init.environ.createMap(arena.allocator()) catch |err|
        fatal("Failed to create env var map: {t}", .{err});
    var g: files.Globals = .init(gpa, io, &env_map);
    defer g.deinit();

    var stdin_buf: [64]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &stdin_buf);
    var stdout_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const argv: [][]const u8 = @ptrCast(@constCast(init.args.toSlice(arena.allocator()) catch
        fatal("Out of memory while parsing args.", .{})));

    const info = getCurrentZigInfo(gpa, &g, .{ .stdout = &stdout.interface });
    defer info.deinit(gpa);
    if (info.used_user_input) {
        pv_store.storePathVersionCwd(&g, info.resolved, info.installed) catch |err|
            log.warn("Failed to store Zig version for this path: {t}", .{err});
    }

    var confirmed_install = info.used_user_input;
    if (!info.installed and !confirmed_install) {
        confirmed_install = if (term.isInteractive())
            confirmInstallPrompt(
                g.getIndex(),
                info.wanted.name(),
                info.resolved.name(),
                &stdin.interface,
                &stdout.interface,
            ) catch |err| fatal("Failed to read input: {t}", .{switch (err) {
                error.EndOfStream => err,
                error.ReadFailed => stdin.err.?,
            }})
        else if (EnvVars.getNonEmpty(&env_map, EnvVars.ALWAYS_INSTALL) == null)
            fatal(
                \\Zig version {s} is not installed.
                \\Non-interactive mode requires the environment variable {s} to be non-empty to automatically install new versions.
            ,
                .{ info.resolved.name(), EnvVars.ALWAYS_INSTALL },
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
        const tmp_dir = files.openTmpDir(io, g.getBaseDir()) catch |err|
            fatal("Failed to create temporary directory: {t}", .{err});
        defer tmp_dir.close(io);
        const mirrors = files.getMirrors(&arena, &g.client, g.getBaseDir()) catch |err| switch (err) {
            error.NoMirrors => @constCast(&.{}),
            else => fatal("Failed to get mirrors list: {t}", .{err}),
        };
        installZig(
            &g,
            tmp_dir,
            mirrors,
            info.resolved,
            &stdout.interface,
        );
        log.info("Cleaning up...", .{});
        LockFile.cleanUpUnlocked(io, tmp_dir) catch {};
    }

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, &env_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    argv[0] = fs.joinPathsInPlace(
        &path_buf,
        base_path.len,
        &.{ files.VERSIONS_DIR, info.resolved.name(), files.ZIG_NAME },
    ) catch |err| fatal("Failed to make path to Zig executable: {t}", .{err});
    replaceWithZig(io, argv, &env_map) catch |err| fatal("Failed to run Zig: {t}", .{err});
    return std.process.cleanExit(io);
}
