const std = @import("std");
const EnvMap = std.process.Environ.Map;

const EnvVar = @This();

name: []const u8,

pub const BASE_DIR: EnvVar = .{ .name = "ZXC_BASE_DIR" };
pub const FORCE_ZIG_VERSION: EnvVar = .{ .name = "ZXC_FORCE_ZIG_VERSION" };
// Only used when non-interactive
pub const ALWAYS_INSTALL: EnvVar = .{ .name = "ZXC_ALWAYS_INSTALL" };

pub fn getNonEmpty(env_map: *const EnvMap, key: EnvVar) ?[]const u8 {
    const value = env_map.get(key.name) orelse return null;
    return if (value.len == 0) null else value;
}
