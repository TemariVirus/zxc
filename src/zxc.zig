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
const zig_cli = @import("zig.zig");
const LockFile = @import("LockFile.zig");

const Args = union(enum) {
    help: void,
    cwd: CwdArgs,
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
        \\  cwd           Set default Zig version for current directory
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
                    if (std.mem.eql(u8, cmd, "cwd")) return .{ .cwd = .parse(p) };
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

const CwdArgs = struct {
    version: []const u8 = "",
    help: bool = false,

    pub const help_text =
        \\Usage: zxc cwd [options] VERSION
        \\
        \\Set default Zig version for the current working directory.
        \\The Zig version is used when build.zig.zon cannot be found.
        \\
        \\Options:
        \\  -h, --help   Print this help message
        \\
    ;

    pub fn parse(p: *lexopts.Parser) CwdArgs {
        var args: CwdArgs = .{};
        while (p.next() catch |err| parserErr(p, err)) |arg| {
            switch (arg) {
                .option => |opt| {
                    if (opt.match(.{ .short = 'h', .long = "help" })) {
                        return .{ .help = true };
                    } else {
                        p.unknownOpt();
                    }
                },
                .pos_arg => |value| {
                    if (args.version.len == 0) {
                        args.version = value;
                    } else {
                        fatal("Too many arguments.", .{});
                    }
                },
            }
        }

        if (args.version.len == 0) {
            fatal("Missing VERSION argument.", .{});
        }
        return args;
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

fn cwdCmd(g: *files.Globals, opts: CwdArgs) void {
    const io = g.getIo();

    var stdout_buf: [1024]u8 = undefined;
    var stdout = File.stdout().writerStreaming(io, &stdout_buf);
    if (opts.help) {
        stdout.interface.writeAll(CwdArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    const version: files.Version = .parseOrCrash(opts.version);
    const versions_dir = g.getBaseDir().openDir(io, files.VERSIONS_DIR, .{}) catch null;
    defer if (versions_dir) |vd| vd.close(io);

    // Ensure version is installed or available in index
    if (versions_dir == null or !files.isZigVersionInstalled(io, versions_dir.?, version.name())) {
        _ = files.getCompatibleZigVersion(g.getIndex(), version) catch |err| switch (err) {
            error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        } orelse fatal("No available Zig version is compatible with {s}", .{opts.version});
    }

    pv_store.storePathVersionCwd(g, version, false) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        error.UnknownVersion => fatal("Could not find version of {s} from index.", .{opts.version}),
        else => fatal("Failed to store Zig version for this path: {t}", .{err}),
    };
}

fn installCmd(g: *files.Globals, opts: InstallArgs) void {
    const allocator = g.getScratchAllocator();
    const io = g.getIo();

    var stdout_buf: [1024]u8 = undefined;
    var stdout = File.stdout().writerStreaming(io, &stdout_buf);
    if (opts.help) {
        stdout.interface.writeAll(InstallArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    const versions_dir = g.getBaseDir().createDirPathOpen(io, files.VERSIONS_DIR, .{}) catch |err|
        fatal("Unable to create versions directory: {t}", .{err});
    defer versions_dir.close(io);
    const tmp_dir = files.openTmpDir(io, g.getBaseDir()) catch |err|
        fatal("Unable to create temporary directory: {t}", .{err});
    defer tmp_dir.close(io);

    const lock = LockFile.lock(allocator, io, tmp_dir, opts.version) catch |err|
        fatal("Failed to create file lock: {t}", .{err});
    defer lock.unlock(allocator, io);
    if (!opts.force and files.isZigVersionInstalled(io, versions_dir, opts.version)) {
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
        if (!files.isZigVersionInstalled(io, work_dir, extracted_name)) {
            fatal(
                \\'{s}' had an unexpected directory structure or is incompatible with your system.
                \\Installable tarballs must have the same structure as the official tarballs.
            , .{filename});
        }
        break :name extracted_name;
    } else name: {
        if (!files.isZigVersionInstalled(io, .cwd(), opts.path)) {
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

fn lsCmd(g: *files.Globals, opts: LsArgs) void {
    const allocator = g.getScratchAllocator();
    const io = g.getIo();

    var stdout_buf: [1024]u8 = undefined;
    var stdout = File.stdout().writerStreaming(io, &stdout_buf);
    if (opts.help) {
        stdout.interface.writeAll(LsArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const versions = files.getAllVersions(
        arena.allocator(),
        io,
        g.env_map,
        g.getBaseDir(),
        // Pass empty index to only get installed versions
        if (opts.all) g.getIndex() else "{}",
    ) catch |err| switch (err) {
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        else => fatal("Unable to retrieve versions: {t}", .{err}),
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

fn realpathCmd(g: *files.Globals) void {
    const allocator = g.getScratchAllocator();
    const io = g.getIo();

    var stdout = File.stdout().writerStreaming(io, &.{});
    const info = zig_cli.getWantedZigInfo(allocator, g, null);
    defer info.deinit(allocator);

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const base_path = files.getBasePath(io, g.env_map, &path_buf) catch |err|
        fatal("Failed to locate base directory: {t}", .{err});
    stdout.interface.print("{f}\n", .{Dir.path.fmtJoin(&.{
        base_path,
        files.VERSIONS_DIR,
        info.resolved.name(),
        files.ZIG_NAME,
    })}) catch {};
    stdout.interface.flush() catch {};
}

fn rmCmd(g: *files.Globals, opts: RmArgs) void {
    const io = g.getIo();

    var stdout_buf: [1024]u8 = undefined;
    var stdout = File.stdout().writerStreaming(io, &stdout_buf);
    if (opts.help) {
        stdout.interface.writeAll(RmArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    const versions_dir = g.getBaseDir().createDirPathOpen(io, files.VERSIONS_DIR, .{}) catch |err|
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

pub fn main(init: std.process.Init) void {
    const io = init.io;
    var g: files.Globals = .init(init.gpa, io, init.environ_map);
    defer g.deinit();

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
        .cwd, .install, .rm => io.concurrent(cleanUp, .{ io, init.environ_map }) catch null,
        else => null, // Operation too short
    };
    defer _ = if (cleanup_task) |*t| t.await(io) catch {};

    switch (args) {
        .help => stdout.interface.writeAll(Args.help_text) catch {},
        .cwd => |opts| cwdCmd(&g, opts),
        .install => |opts| installCmd(&g, opts),
        .ls => |opts| lsCmd(&g, opts),
        .realpath => realpathCmd(&g),
        .rm => |opts| rmCmd(&g, opts),
        .version => stdout.interface.writeAll(options.version ++ "\n") catch {},
    }
    stdout.flush() catch {};

    std.process.cleanExit(io);
}
