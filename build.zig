const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Default install step
    const zig_exe, const zxc_exe = try buildExes(b, target, optimize);
    b.installArtifact(zig_exe);
    b.installArtifact(zxc_exe);

    const test_step = b.step("test", "Run tests");
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_options = b.addOptions();
    test_options.addOptionPath("zig_path", zig_exe.getEmittedBin());
    test_options.addOptionPath("zxc_path", zxc_exe.getEmittedBin());
    test_exe.root_module.addImport("options", test_options.createModule());
    const run_test = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_test.step);

    const release_step = b.step("release", "Compile release binaries");
    inline for ([_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .cpu_model = .baseline },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .cpu_model = .baseline },
        .{ .cpu_arch = .aarch64, .os_tag = .macos, .cpu_model = .baseline },
        .{ .cpu_arch = .x86_64, .os_tag = .macos, .cpu_model = .baseline },
    }) |tq| {
        try installReleaseArtifact(b, b.resolveTargetQuery(tq), release_step);
    }
}

fn getOwnVersion(allocator: std.mem.Allocator) ![]const u8 {
    var diag: std.zon.parse.Diagnostics = undefined;
    const zon = try std.zon.parse.fromSlice(
        struct { version: []const u8 },
        .{
            .gpa = allocator,
            .arena = allocator,
            .source = @embedFile("build.zig.zon"),
            .diagnostics = &diag,
            .ignore_unknown_fields = true,
        },
    );
    return zon.version;
}

fn buildExes(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) !struct { *Build.Step.Compile, *Build.Step.Compile } {
    const strip = switch (optimize) {
        .debug, .safe => false,
        .fast, .small => true,
    };
    const link_libc = target.result.os.tag != .linux;

    const zig_exe = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zig.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = link_libc,
        }),
        .linkage = if (link_libc) .dynamic else .static,
    });
    const zxc_exe = b.addExecutable(.{
        .name = "zxc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zxc.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = link_libc,
        }),
        .linkage = if (link_libc) .dynamic else .static,
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
        .@"no-cli" = true,
    }).module("minizign");
    zig_exe.root_module.addImport("minizign", minizign);

    const options = b.addOptions();
    options.addOption([]const u8, "version", try getOwnVersion(b.allocator));
    zig_exe.root_module.addImport("options", options.createModule());
    zxc_exe.root_module.addImport("options", options.createModule());

    return .{ zig_exe, zxc_exe };
}

fn installReleaseArtifact(b: *Build, target: Build.ResolvedTarget, step: *Build.Step) !void {
    const zig_exe, const zxc_exe = try buildExes(b, target, .small);
    const archive_path = b.fmt(
        "release/{t}-{t}-zxc",
        .{ target.result.cpu.arch, target.result.os.tag },
    );
    step.dependOn(&b.addInstallArtifact(
        zig_exe,
        .{ .dest_dir = .{ .override = .{ .custom = archive_path } } },
    ).step);
    step.dependOn(&b.addInstallArtifact(
        zxc_exe,
        .{ .dest_dir = .{ .override = .{ .custom = archive_path } } },
    ).step);
}
