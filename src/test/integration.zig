const std = @import("std");
const testing = std.testing;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

const options = @import("options");
const Container = @import("Container.zig");
const EnvVar = @import("../EnvVar.zig");
const files = @import("../files.zig");

/// Testing-only container-like environment. The filesystem root is mounted
/// onto a temporary directory and network access is disabled.
const Jail = struct {
    tmp: testing.TmpDir,
    /// This is meant to be modified directly
    env: EnvMap,

    const gpa = testing.allocator;
    const io = testing.io;

    pub fn init() Jail {
        const tmp = testing.tmpDir(.{});
        const env_map: EnvMap = .init(gpa);
        return .{ .tmp = tmp, .env = env_map };
    }

    pub fn deinit(self: *Jail) void {
        self.tmp.cleanup();
        self.env.deinit();
        self.* = undefined;
    }

    /// Copies the file at `src_path` into the Jail environment.
    /// Tries to hardlink when possible.
    pub fn linkFile(self: Jail, src_path: []const u8, dst_path: []const u8) void {
        Dir.hardLink(
            .cwd(),
            src_path,
            self.tmp.dir,
            dst_path,
            io,
            .{ .follow_symlinks = true },
        ) catch Dir.copyFile(
            .cwd(),
            src_path,
            self.tmp.dir,
            dst_path,
            io,
            .{ .make_path = true, .replace = false },
        ) catch std.debug.panic("Failed to copy {s} to {s} in jail", .{ src_path, dst_path });
    }

    /// Creates a new file in the Jail environment.
    pub fn printFile(
        self: Jail,
        dst_path: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const f = self.tmp.dir.createFile(io, dst_path, .{ .exclusive = true }) catch
            std.debug.panic("Failed to create {s} in jail", .{dst_path});
        defer f.close(io);

        var buf: [4096]u8 = undefined;
        var writer = f.writerStreaming(io, &buf);
        writer.interface.print(fmt, args) catch
            std.debug.panic("Failed to write {s} in jail: {t}", .{ dst_path, writer.err.? });
        writer.flush() catch |err|
            std.debug.panic("Failed to write {s} in jail: {t}", .{ dst_path, err });
    }

    fn allocStdio(allocator: std.mem.Allocator, stdio: std.Io.File) ![]const u8 {
        var reader = stdio.readerStreaming(io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(100 * 1024)) catch |err| switch (err) {
            error.ReadFailed => reader.err.?,
            else => |e| e,
        };
    }

    /// Runs the command and allocates its stdout with `allocator`.
    pub fn run(self: Jail, allocator: std.mem.Allocator, argv: []const []const u8) !Run {
        var proc: Container = try .spawn(gpa, io, .{
            .argv = argv,
            .cwd = .{ .dir = self.tmp.dir },
            .environ_map = &self.env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer proc.kill();

        // We must read stdout and stderr asynchronously to prevent the pipes
        // from backing up and blocking the container process
        var stdout_task = io.async(allocStdio, .{ allocator, proc.stdout.? });
        errdefer if (stdout_task.cancel(io)) |s| allocator.free(s) else |_| {};
        var stderr_task = io.async(allocStdio, .{ allocator, proc.stderr.? });
        errdefer if (stderr_task.cancel(io)) |s| allocator.free(s) else |_| {};

        const stdout = try stdout_task.await(io);
        const stderr = try stderr_task.await(io);
        const term = try proc.wait();
        return .{
            .allocator = allocator,
            .env = &self.env,
            .term = term,
            .stdout = stdout,
            .stderr = stderr,
        };
    }
};

const Run = struct {
    allocator: std.mem.Allocator,
    env: *const EnvMap,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: Run) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn expectTerm(self: Run, expected: std.process.Child.Term) !void {
        try testing.expectEqual(expected, self.term);
    }

    pub fn expectVersionStdout(self: Run, version: []const u8) !void {
        const base_dir = self.env.get(EnvVar.BASE_DIR.name) orelse @panic("No base dir");
        var buf: [Dir.max_path_bytes + 1]u8 = undefined;
        const expected = std.mem.print(&buf, "{f}\n", .{
            Dir.path.fmtJoin(&.{ base_dir, "versions", version, files.ZIG_NAME }),
        }) catch @panic("Path too long");
        try testing.expectEqualStrings(expected, self.stdout);
    }

    pub fn dumpStderr(self: Run) void {
        testing.failPrint("{s}", .{self.stderr});
    }
};

test "cwd command" {
    const gpa = testing.allocator;

    var jail: Jail = .init();
    defer jail.deinit();
    jail.linkFile(options.zxc_path, "zxc");
    jail.printFile(files.INDEX_PATH,
        \\{{
        \\  "1.2.3": {{
        \\    "{s}": {{}}
        \\  }}
        \\}}
    , .{files.SELF_TARGET});
    try jail.env.put(EnvVar.BASE_DIR.name, "/");

    {
        const run = try jail.run(gpa, &.{ "zxc", "realpath" });
        defer run.deinit();
        try run.expectTerm(.{ .exited = 1 });
    }
    {
        const run = try jail.run(gpa, &.{ "zxc", "cwd", "1.2.3" });
        defer run.deinit();
        try run.expectTerm(.{ .exited = 0 });
    }
    {
        const run = try jail.run(gpa, &.{ "zxc", "realpath" });
        defer run.deinit();
        try run.expectTerm(.{ .exited = 0 });
        try run.expectVersionStdout("1.2.3");
    }
}
