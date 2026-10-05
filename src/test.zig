const std = @import("std");
const testing = std.testing;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

const options = @import("options");
const files = @import("files.zig");
const fs = @import("fs.zig");
const EnvVar = @import("EnvVar.zig");

test "Unit tests" {
    _ = @import("files.zig");
}

fn resolvePath(io: std.Io, path: []const u8, buf: []u8) []const u8 {
    if (Dir.path.isAbsolute(path)) {
        return path;
    }
    const cwd_len = std.process.currentPath(io, buf) catch @panic("Unable to get current path");
    return fs.joinPathsInPlace(buf, cwd_len, &.{path}) catch @panic("Path too long");
}

fn runZxc(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: Dir,
    env_map: *const EnvMap,
    comptime args: []const []const u8,
) ![]const u8 {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const zxc_path = resolvePath(io, options.zxc_path, &path_buf);
    // TODO: spawn in namespace so that parent directories cannot be found
    // TODO: disallow network access
    var zxc = try std.process.spawn(io, .{
        .argv = [1][]const u8{zxc_path} ++ args,
        .cwd = .{ .dir = cwd },
        .environ_map = env_map,

        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer zxc.kill(io);

    var buf: [512]u8 = undefined;
    var reader = zxc.stdout.?.readerStreaming(io, &buf);
    const stdout = try reader.interface.allocRemaining(gpa, .unlimited);
    errdefer gpa.free(stdout);

    const term = try zxc.wait(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    return stdout;
}

fn versionPath(comptime version: []const u8) []const u8 {
    return comptime std.fmt.comptimePrint("{f}", .{
        Dir.path.fmtJoin(&.{ ".", "versions", version, files.ZIG_NAME }),
    }) ++ "\n";
}

test "cwd command" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env_map: EnvMap = .init(gpa);
    defer env_map.deinit();
    try env_map.put(EnvVar.BASE_DIR.name, ".");

    gpa.free(try runZxc(gpa, io, tmp.dir, &env_map, &.{ "cwd", "1.2.3" }));
    const realpath = try runZxc(gpa, io, tmp.dir, &env_map, &.{"realpath"});
    defer gpa.free(realpath);
    try testing.expectEqualStrings(versionPath("1.2.3"), realpath);
}
