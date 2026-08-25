const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    try installExes(b, "bin", target, optimize, b.getInstallStep());

    const release_step = b.step("release", "Compile release binaries");
    inline for ([_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
    }) |tq| {
        try installExes(
            b,
            std.fmt.comptimePrint("release/{t}-{t}", .{ tq.cpu_arch.?, tq.os_tag.? }),
            b.resolveTargetQuery(tq),
            .ReleaseSmall,
            release_step,
        );
    }
}

fn getOwnVersion(allocator: std.mem.Allocator) ![]const u8 {
    const zon = try std.zon.parse.fromSliceAlloc(
        struct { version: []const u8 },
        allocator,
        @embedFile("build.zig.zon"),
        null,
        .{ .ignore_unknown_fields = true },
    );
    return zon.version;
}

fn installExes(
    b: *std.Build,
    comptime folder: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step: *std.Build.Step,
) !void {
    const strip = switch (optimize) {
        .debug, .safe => false,
        .fast, .small => true,
    };

    const zig_exe = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zig.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    const zxc_exe = b.addExecutable(.{
        .name = "zxc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zxc.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");
    zig_exe.root_module.addImport("known-folders", known_folders);
    zxc_exe.root_module.addImport("known-folders", known_folders);

    const lexopts = b.dependency("lexopts", .{
        .target = target,
        .optimize = optimize,
    }).module("lexopts");
    zxc_exe.root_module.addImport("lexopts", lexopts);

    const minizign = b.dependency("minizign", .{
        .target = target,
        .optimize = optimize,
    }).module("minizign");
    zig_exe.root_module.addImport("minizign", minizign);

    const options = b.addOptions();
    options.addOption([]const u8, "version", try getOwnVersion(b.allocator));
    zig_exe.root_module.addImport("options", options.createModule());
    zxc_exe.root_module.addImport("options", options.createModule());

    step.dependOn(&b.addInstallArtifact(zig_exe, .{
        .dest_dir = .{ .override = .{ .custom = folder } },
        .dest_sub_path = "zig",
    }).step);
    step.dependOn(&b.addInstallArtifact(zxc_exe, .{
        .dest_dir = .{ .override = .{ .custom = folder } },
        .dest_sub_path = "zxc",
    }).step);
}
