const std = @import("std");
const log = std.log.default;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const EnvMap = std.process.Environ.Map;
const fatal = std.process.fatal;

const lexopts = @import("lexopts");
const options = @import("options");

const files = @import("files.zig");
const fs = @import("fs.zig");
const http = @import("http.zig");
const pv_store = @import("path_version_store.zig");
const term = @import("term.zig");
const LockFile = @import("LockFile.zig");

const Args = union(enum) {
    help: void,
    install: InstallArgs,
    ls: LsArgs,
    realpath: RealpathArgs,
    rm: RmArgs,
    version: void,

    pub const help_text =
        \\Usage: zxc COMMAND [options] [ARGS...]
        \\
        \\Simple Zig version manager.
        \\Run `zxc COMMAND --help` for command-specific help.
        \\
        \\Commands:
        \\  i, install    Install a Zig version
        \\  ls            List Zig versions
        \\  rp, realpath  Print the current Zig executable
        \\  rm            Delete an installed Zig version
        \\  version       Prints the program's version
        \\
        \\Options:
        \\  -h, --help    Print this help message
        \\
    ;

    pub fn parse(p: *lexopts.Parser) ?Args {
        if (p.next() catch |err| parserErr(p, err)) |arg| {
            switch (arg) {
                .option => |opt| {
                    if (opt.match(.{ .short = 'h', .long = "help" })) return .help;
                    if (opt.match(.{ .short = 'v', .long = "version" })) return .version;
                    p.unknownOpt();
                },
                .pos_arg => |cmd| {
                    if (std.mem.eql(u8, cmd, "i") or std.mem.eql(u8, cmd, "install")) return .{ .install = .parse(p) };
                    if (std.mem.eql(u8, cmd, "ls")) return .{ .ls = .parse(p) };
                    if (std.mem.eql(u8, cmd, "rm")) return .{ .rm = .parse(p) };
                    if (std.mem.eql(u8, cmd, "rp") or std.mem.eql(u8, cmd, "realpath")) return .{ .realpath = .parse(p) };
                    if (std.mem.eql(u8, cmd, "version")) return .version;
                    fatal("Unknown command '{s}'. Run `zxc --help` for a list of commands.", .{cmd});
                },
            }
        }
        return null;
    }
};

const InstallArgs = struct {
    /// Valid semantic version, or "master".
    version: []const u8 = "",
    path: []const u8 = "",
    force: bool = false,
    help: bool = false,

    pub const help_text =
        \\Usage: zxc install [options] VERSION PATH
        \\
        \\Install a Zig version from the tarball or directory at PATH.
        \\VERSION should match the expected .minimum_zig_version field of build.zig.zon
        \\
        \\Supported tarball formats: .tar.xz, .zip
        \\
        \\Options:
        \\  -f, --force  Overwrite the already installed version, if it exists
        \\  -h, --help   Print this help message
        \\
    ;

    pub fn parse(p: *lexopts.Parser) InstallArgs {
        var args: InstallArgs = .{};
        while (p.next() catch |err| parserErr(p, err)) |arg| {
            switch (arg) {
                .option => |opt| {
                    if (opt.match(.{ .short = 'f', .long = "force" })) {
                        args.force = true;
                    } else if (opt.match(.{ .short = 'h', .long = "help" })) {
                        return .{ .help = true };
                    } else {
                        p.unknownOpt();
                    }
                },
                .pos_arg => |value| {
                    if (args.version.len == 0) {
                        args.version = value;
                    } else if (args.path.len == 0) {
                        args.path = value;
                    } else {
                        fatal("Too many arguments.", .{});
                    }
                },
            }
        }

        if (args.version.len == 0) {
            fatal("Missing VERSION argument.", .{});
        }
        const is_semver = !std.meta.isError(std.SemanticVersion.parse(args.version));
        if (!LockFile.isValidKey(args.version) or
            (!std.mem.eql(u8, args.version, "master") and !is_semver))
        {
            fatal("Invalid version {s}\nVERSION argument must be a semantic version, or \"master\".", .{args.version});
        }
        if (args.path.len == 0) {
            fatal("Missing PATH argument.", .{});
        }
        return args;
    }
};

const LsArgs = struct {
    all: bool = false,
    help: bool = false,
    name_only: bool = false,

    pub const help_text =
        \\Usage: zxc ls [options]
        \\
        \\List installed Zig versions.
        \\
        \\Options:
        \\  -a, --all        Also list versions available for download online
        \\  -h, --help       Print this help message
        \\  -n, --name-only  Only print version name
        \\
    ;

    pub fn parse(p: *lexopts.Parser) LsArgs {
        var args: LsArgs = .{};
        while (p.next() catch |err| parserErr(p, err)) |arg| {
            switch (arg) {
                .option => |opt| {
                    if (opt.match(.{ .short = 'a', .long = "all" })) {
                        args.all = true;
                    } else if (opt.match(.{ .short = 'h', .long = "help" })) {
                        return .{ .help = true };
                    } else if (opt.match(.{ .short = 'n', .long = "name-only" })) {
                        args.name_only = true;
                    } else {
                        p.unknownOpt();
                    }
                },
                .pos_arg => fatal("`zxc ls` does not accept arguments. Run `zxc ls --help` for help.", .{}),
            }
        }
        return args;
    }
};

const RealpathArgs = struct {
    pub fn parse(p: *lexopts.Parser) RealpathArgs {
        while (p.next() catch |err| parserErr(p, err)) |_| {
            fatal("`zxc realpath` does not accept arguments. Run `zxc --help` for help.", .{});
        }
        return .{};
    }
};

const RmArgs = struct {
    help: bool = false,
    parser: *lexopts.Parser = undefined,

    pub const help_text =
        \\Usage: zxc rm VERSIONS...
        \\
        \\Delete previously installed Zig versions.
        \\
        \\Options:
        \\  -h, --help  Print this help message
        \\
    ;

    pub fn parse(p: *lexopts.Parser) RmArgs {
        std.debug.assert(p.args == .slice);

        const old_parser = p.*;
        const args: RmArgs = .{ .parser = p };
        var has_version = false;
        while (p.next() catch |err| parserErr(p, err)) |arg| switch (arg) {
            .option => |opt| {
                if (opt.match(.{ .short = 'h', .long = "help" })) {
                    return .{ .help = true };
                } else {
                    p.unknownOpt();
                }
            },
            .pos_arg => has_version = true,
        };

        if (!has_version) {
            fatal("Missing VERSIONS argument(s).", .{});
        }
        p.* = old_parser;
        return args;
    }

    pub fn nextVersion(self: RmArgs) ?[]const u8 {
        while (self.parser.next() catch |err| parserErr(self.parser, err)) |arg| {
            switch (arg) {
                .option => continue,
                .pos_arg => |ver| return ver,
            }
        }
        return null;
    }
};

fn parserErr(p: *const lexopts.Parser, err: lexopts.LexoptsError) noreturn {
    switch (err) {
        error.UnexpectedValue => p.unexpectedValue(),
        error.UnknownOption => p.unknownOpt(),
        error.MissingValue => p.missingValue(),
    }
}

fn installCmd(
    allocator: std.mem.Allocator,
    io: Io,
    env_map: *const EnvMap,
    opts: InstallArgs,
) void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = File.stdout().writerStreaming(io, &stdout_buf);
    if (opts.help) {
        stdout.interface.writeAll(InstallArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, env_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    const versions_dir = blk: {
        const versions_path = fs.joinPathsInPlace(&path_buf, base_path.len, &.{files.VERSIONS_DIR}) catch
            fatal("Out of memory.", .{});
        break :blk Dir.createDirPathOpen(.cwd(), io, versions_path, .{}) catch |err|
            fatal("Unable to open versions directory: {t}", .{err});
    };
    defer versions_dir.close(io);
    const tmp_dir = blk: {
        const tmp_path = fs.joinPathsInPlace(&path_buf, base_path.len, &.{"tmp"}) catch
            fatal("Out of memory.", .{});
        break :blk Dir.createDirPathOpen(.cwd(), io, tmp_path, .{}) catch |err|
            fatal("Unable to open temporary directory: {t}", .{err});
    };
    defer tmp_dir.close(io);

    const lock = LockFile.lock(allocator, io, tmp_dir, opts.version) catch |err|
        fatal("Failed to create file lock: {t}", .{err});
    defer lock.unlock(allocator, io);
    if (!opts.force and files.isZigVersionInstalledDir(io, versions_dir, opts.version)) {
        fatal("Zig version {s} is already installed. Add the --force flag to overwrite it.", .{opts.version});
    }

    const work_dir = lock.getLockedDir(io, .{}) catch |err|
        fatal("Failed to create temporary directory: {t}", .{err});
    defer {
        work_dir.close(io);
        tmp_dir.deleteTree(io, opts.version) catch {};
    }

    const archive_file = Dir.cwd().openFile(io, opts.path, .{
        .allow_directory = false,
        .follow_symlinks = true,
        .resolve_beneath = false,
    }) catch |err| switch (err) {
        error.IsDir => null,
        else => fatal("Unable to open {s}: {t}", .{ opts.path, err }),
    };
    defer if (archive_file) |f| f.close(io);

    const old_name = if (archive_file) |f| name: {
        const filename = Dir.path.basename(opts.path);
        log.info("Extracting '{s}'...", .{filename});
        const extracted_name = files.extractZigTarball(allocator, io, f, filename, work_dir) catch |err|
            fatal("Failed to extract '{s}': {t}", .{ filename, err });
        if (!files.isZigVersionInstalledDir(io, work_dir, extracted_name)) {
            fatal(
                \\'{s}' had an unexpected directory structure or is incompatible with your system.
                \\Installable tarballs must have the same structure as the official tarballs.
            , .{filename});
        }
        break :name extracted_name;
    } else name: {
        if (!files.isZigVersionInstalledDir(io, .cwd(), opts.path)) {
            fatal("'{s}' does not contain an executable {s} file.", .{ opts.path, files.ZIG_NAME });
        }
        log.info("Copying '{s}'...", .{opts.path});
        fs.copyTree(.cwd(), opts.path, work_dir, opts.version, null, io) catch |err|
            fatal("Failed to copy '{s}': {t}", .{ opts.path, err });
        break :name opts.version;
    };

    fs.forceRename(work_dir, old_name, versions_dir, opts.version, io) catch |err|
        fatal("Failed to install {s}: {t}", .{ opts.version, err });

    stdout.interface.print("Installed {s}!\n", .{opts.version}) catch {};
    stdout.flush() catch {};
}

fn lsCmd(
    allocator: std.mem.Allocator,
    io: Io,
    env_map: *const EnvMap,
    opts: LsArgs,
) void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = File.stdout().writerStreaming(io, &stdout_buf);
    if (opts.help) {
        stdout.interface.writeAll(LsArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, env_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    const versions_path = fs.joinPathsInPlace(&path_buf, base_path.len, &.{files.VERSIONS_DIR}) catch
        fatal("Out of memory.", .{});

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const versions = if (opts.all) blk: {
        const base_dir = Dir.createDirPathOpen(.cwd(), io, base_path, .{}) catch |err|
            fatal("Failed to open base directory '{s}': {t}", .{ base_path, err });
        defer base_dir.close(io);
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        const index = files.getIndex(allocator, &client, base_dir) catch |err|
            fatal("Failed to get index: {t}", .{err});
        defer allocator.free(index);
        break :blk files.getAllVersions(arena.allocator(), io, versions_path, index) catch |err| switch (err) {
            error.OutOfMemory => fatal("Out of memory.", .{}),
            error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
            else => fatal("Unable to open versions directory: {t}", .{err}),
        };
    } else
        // Pass empty index to only get installed versions
        files.getAllVersions(arena.allocator(), io, versions_path, "{}") catch |err| switch (err) {
            error.OutOfMemory => fatal("Out of memory.", .{}),
            error.UnexpectedFormat => unreachable,
            else => fatal("Unable to open versions directory: {t}", .{err}),
        };

    std.sort.pdq(files.ZigVersion, versions, {}, files.ZigVersion.greaterThan);

    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    if (versions.len == 0 and !opts.all) {
        stdout.interface.writeAll("No Zig versions installed.\n") catch {};
    } else for (versions) |v| {
        // Duplicates can only occur between installed and non-installed versions,
        // and other information is not printed to differentiate them
        if (opts.name_only and opts.all) {
            const seen_name = blk: {
                const result = seen.getOrPut(v.name) catch break :blk false;
                break :blk result.found_existing;
            };
            if (seen_name) continue;
        }

        stdout.interface.print("{s}", .{v.name}) catch {};
        if (!opts.name_only) if (v.version) |ver| {
            stdout.interface.print(" ({s})", .{ver}) catch {};
        };
        if (!opts.name_only and opts.all and v.installed) {
            stdout.interface.writeAll(" [Installed]") catch {};
        }
        stdout.interface.writeAll("\n") catch {};
    }
    stdout.flush() catch {};
}

fn realpathCmd(
    allocator: std.mem.Allocator,
    io: Io,
    env_map: *const EnvMap,
) void {
    const zig_cli = @import("zig.zig");

    var stdout = File.stdout().writerStreaming(io, &.{});
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const info = zig_cli.getWantedZigInfo(allocator, &client, env_map, &stdout.interface, false);
    defer info.deinit(allocator);

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, env_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    const versions_path = fs.joinPathsInPlace(&path_buf, base_path.len, &.{files.VERSIONS_DIR}) catch
        fatal("Out of memory.", .{});

    const zig_path = fs.joinPathsInPlace(&path_buf, versions_path.len, &.{ info.resolved_version, files.ZIG_NAME }) catch
        fatal("Out of memory.", .{});
    stdout.interface.print("{s}\n", .{zig_path}) catch {};
    stdout.interface.flush() catch {};
}

fn rmCmd(io: Io, env_map: *const EnvMap, opts: RmArgs) void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = File.stdout().writerStreaming(io, &stdout_buf);
    if (opts.help) {
        stdout.interface.writeAll(RmArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, env_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    const versions_path = fs.joinPathsInPlace(&path_buf, base_path.len, &.{files.VERSIONS_DIR}) catch
        fatal("Out of memory.", .{});

    const versions_dir = Dir.createDirPathOpen(.cwd(), io, versions_path, .{}) catch |err|
        fatal("Unable to open versions directory: {t}", .{err});
    defer versions_dir.close(io);
    version_loop: while (opts.nextVersion()) |version| {
        // Prevent path traversal
        for (version) |c| if (Dir.path.isSep(c)) {
            log.err("Invalid version: {s}", .{version});
            continue :version_loop;
        };

        versions_dir.access(io, version, .{}) catch {
            log.info("{s} is not installed", .{version});
            continue;
        };
        versions_dir.deleteTree(io, version) catch |err| {
            log.err("Failed to remove {s}: {t}", .{ version, err });
            continue;
        };
        stdout.interface.print("Removed {s}\n", .{version}) catch {};
        stdout.flush() catch {};
    }
}

fn cleanUpInner(io: Io, env_map: *const EnvMap) !void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = try files.getBasePath(io, env_map, &path_buf);
    const base_dir = try Dir.openDirAbsolute(io, base_path, .{});
    defer base_dir.close(io);
    try pv_store.cleanUpEntries(io, base_dir);

    const tmp_dir = try files.openTmpDir(io, base_dir);
    defer tmp_dir.close(io);
    try LockFile.cleanUpUnlocked(io, tmp_dir);
}

fn cleanUp(io: Io, env_map: *const EnvMap) Io.Cancelable!void {
    cleanUpInner(io, env_map) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return,
    };
}

// TODO: add command to set Zig version for cwd
pub fn main(init: std.process.Init) void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout = File.stdout().writerStreaming(io, &.{});
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch
        fatal("Out of memory while parsing args.", .{});
    var parser: lexopts.Parser = .init(argv);

    const args = Args.parse(&parser) orelse {
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        const stderr = io.lockStderr(&.{}, null) catch unreachable;
        defer io.unlockStderr();

        stderr.file_writer.interface.writeAll(Args.help_text) catch {};
        std.process.exit(1);
    };

    var cleanup_task = switch (args) {
        .install, .rm => io.concurrent(cleanUp, .{ io, init.environ_map }) catch null,
        else => null, // Operation too short
    };
    defer _ = if (cleanup_task) |*t| t.cancel(io) catch {};

    switch (args) {
        .help => stdout.interface.writeAll(Args.help_text) catch {},
        .install => |opts| installCmd(gpa, io, init.environ_map, opts),
        .ls => |opts| lsCmd(gpa, io, init.environ_map, opts),
        .realpath => realpathCmd(gpa, io, init.environ_map),
        .rm => |opts| rmCmd(io, init.environ_map, opts),
        .version => stdout.interface.writeAll(options.version ++ "\n") catch {},
    }
    stdout.flush() catch {};

    std.process.cleanExit(io);
}
