const std = @import("std");
const log = std.log.default;
const Io = std.Io;
const fatal = std.process.fatal;

const lexopts = @import("lexopts");
const options = @import("options");

const files = @import("files.zig");

const Args = union(enum) {
    help: void,
    ls: LsArgs,
    rm: RmArgs,
    version: void,

    pub const help_text =
        \\Usage: zxc COMMAND [options] [ARGS...]
        \\
        \\Simple Zig version manager.
        \\Run `zxc COMMAND --help` for command-specific help.
        \\
        \\Commands:
        \\  ls          List Zig versions.
        \\  rm          Delete an installed Zig version.
        \\  version     Prints the program's version.
        \\
        \\Options:
        \\  -h, --help  Print this help message.
        \\
    ;

    pub fn parse(p: *lexopts.Parser) ?Args {
        if (p.next() catch |err| parserErr(p, err)) |arg| {
            switch (arg) {
                .option => |opt| {
                    if (opt.match("-h") or opt.match("--help")) return .help;
                    if (opt.match("-v") or opt.match("--version")) return .version;
                    p.unknownOpt();
                },
                .pos_arg => |cmd| {
                    if (std.mem.eql(u8, cmd, "ls")) return .{ .ls = .parse(p) };
                    if (std.mem.eql(u8, cmd, "rm")) return .{ .rm = .parse(p) };
                    if (std.mem.eql(u8, cmd, "version")) return .version;
                    std.process.fatal("Unknown command '{s}'. Run `zxc --help` for a list of commands.", .{cmd});
                },
            }
        }
        return null;
    }
};

const LsArgs = struct {
    all: bool = false,
    help: bool = false,

    pub const help_text =
        \\Usage: zxc ls [options]
        \\
        \\List installed Zig versions.
        \\
        \\Options:
        \\  -a, --all   Also list versions available for download online.
        \\  -h, --help  Print this help message.
        \\
    ;

    pub fn parse(p: *lexopts.Parser) LsArgs {
        var args: LsArgs = .{};
        while (p.next() catch |err| parserErr(p, err)) |arg| {
            switch (arg) {
                .option => |opt| {
                    if (opt.match("-a") or opt.match("--all")) {
                        args.all = true;
                    } else if (opt.match("-h") or opt.match("--help")) {
                        return .{ .help = true };
                    } else {
                        p.unknownOpt();
                    }
                },
                .pos_arg => std.process.fatal("`zxc ls` does not accept arguments. Run `zxc ls --help` for help.", .{}),
            }
        }
        return args;
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
        \\  -h, --help  Print this help message.
        \\
    ;

    pub fn parse(p: *lexopts.Parser) RmArgs {
        std.debug.assert(p.args == .slice);

        const old_parser = p.*;
        const args: RmArgs = .{ .parser = p };
        var has_version = false;
        while (p.next() catch |err| parserErr(p, err)) |arg| switch (arg) {
            .option => |opt| {
                if (opt.match("-h") or opt.match("--help")) {
                    return .{ .help = true };
                } else {
                    p.unknownOpt();
                }
            },
            .pos_arg => has_version = true,
        };

        if (!has_version) {
            std.process.fatal("Missing VERSIONS argument(s).", .{});
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

fn lsAll(
    allocator: std.mem.Allocator,
    io: Io,
    base_dir: Io.Dir,
    stdout: *Io.Writer,
) void {
    const index = blk: {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        break :blk files.getIndex(allocator, io, &client, base_dir) catch |err|
            fatal("Failed to get index: {t}", .{err});
    };
    defer allocator.free(index);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const versions = files.getAllVersions(arena.allocator(), io, base_dir, index) catch |err| switch (err) {
        error.OutOfMemory => fatal("Out of memory", .{}),
        error.UnexpectedFormat => fatal("Unexpected format for index file. Please update your zxc version.", .{}),
        else => fatal("Unable to open versions folder: {t}", .{err}),
    };
    std.sort.pdq(files.ZigVersion, versions, {}, files.ZigVersion.greaterThan);
    for (versions) |v| {
        stdout.print("{f}\n", .{v}) catch {};
    }
    stdout.flush() catch {};
}

fn lsCmd(
    allocator: std.mem.Allocator,
    io: Io,
    base_dir: Io.Dir,
    opts: LsArgs,
) void {
    var stdout_buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);

    if (opts.help) {
        stdout.interface.writeAll(LsArgs.help_text) catch {};
        return stdout.flush() catch {};
    }
    if (opts.all) {
        return lsAll(allocator, io, base_dir, &stdout.interface);
    }

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    // Pass empty index to only get installed versions
    const versions = files.getAllVersions(arena.allocator(), io, base_dir, "{}") catch |err| switch (err) {
        error.OutOfMemory => fatal("Out of memory", .{}),
        error.UnexpectedFormat => unreachable,
        else => fatal("Unable to open versions folder: {t}", .{err}),
    };
    std.sort.pdq(files.ZigVersion, versions, {}, files.ZigVersion.greaterThan);

    if (versions.len == 0) {
        stdout.interface.writeAll("No Zig versions installed.\n") catch {};
    } else for (versions) |v| {
        if (v.version) |ver| {
            stdout.interface.print("{s} ({s})\n", .{ v.name, ver }) catch {};
        } else {
            stdout.interface.print("{s}\n", .{v.name}) catch {};
        }
    }
    stdout.flush() catch {};
}

fn rmCmd(io: Io, base_dir: Io.Dir, opts: RmArgs) void {
    var stdout_buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);

    if (opts.help) {
        stdout.interface.writeAll(RmArgs.help_text) catch {};
        return stdout.flush() catch {};
    }

    const versions_dir = base_dir.createDirPathOpen(io, files.VERSIONS_DIR, .{}) catch |err|
        fatal("Unable to open versions folder: {t}", .{err});
    defer versions_dir.close(io);
    version_loop: while (opts.nextVersion()) |version| {
        // Prevent path traversal
        for (version) |c| if (Io.Dir.path.isSep(c)) {
            log.err("Invalid version: {s}", .{version});
            continue :version_loop;
        };

        versions_dir.deleteTree(io, version) catch |err| {
            log.err("Failed to remove {s}: {t}", .{ version, err });
            continue;
        };
        stdout.interface.print("Removed {s}\n", .{version}) catch {};
        stdout.flush() catch {};
    }
}

// TODO: add command to allow users to add their own version
// This is as simple as copying the folder into the versions directory
// TODO: add command to get path to current zig executable
pub fn main(init: std.process.Init) void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout = Io.File.stdout().writer(io, &.{});
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch
        fatal("Out of memory while parsing args", .{});
    var parser: lexopts.Parser = .init(argv);

    const args = Args.parse(&parser) orelse {
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        const stderr = io.lockStderr(&.{}, null) catch unreachable;
        defer io.unlockStderr();

        stderr.file_writer.interface.writeAll(Args.help_text) catch {};
        std.process.exit(1);
    };
    switch (args) {
        .help => stdout.interface.writeAll(Args.help_text) catch {},
        .ls => |opts| {
            const base_dir = files.openBaseDir(gpa, io, init.environ_map);
            defer base_dir.close(io);
            lsCmd(gpa, io, base_dir, opts);
        },
        .rm => |opts| {
            const base_dir = files.openBaseDir(gpa, io, init.environ_map);
            defer base_dir.close(io);
            rmCmd(io, base_dir, opts);
        },
        .version => stdout.interface.writeAll(options.version ++ "\n") catch {},
    }
    stdout.flush() catch {};

    std.process.cleanExit(io);
}
