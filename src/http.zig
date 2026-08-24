const std = @import("std");
const log = std.log.default;
const Client = std.http.Client;
const fatal = std.process.fatal;

const minizign = @import("minizign");
const options = @import("options");

const files = @import("files.zig");

const NAME = "zxc";
const MAX_MIRROR_URL_LEN = 512;
const MINISIGN_KEY = minizign.PublicKey.decodeFromBase64("RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U") catch @compileError("Bad minisign key");

pub const FetchResult = struct {
    request: Client.Request,
    transfer_buffer: [64]u8 = undefined,
    decompress_buffer: []u8,
    decompress: std.http.Decompress,
    /// When `error.ReadFailed` is returned, use `getReadErr()` to get a more specific error.
    reader: *std.Io.Reader,

    pub fn deinit(self: *FetchResult) void {
        const allocator = self.request.client.allocator;
        allocator.free(self.decompress_buffer);
        self.request.deinit();
        allocator.destroy(self);
    }

    pub fn getReadErr(self: *FetchResult) std.http.Reader.BodyError {
        return self.request.reader.body_err.?;
    }
};

pub fn fetch(client: *Client, uri: std.Uri) !*FetchResult {
    var result = try client.allocator.create(FetchResult);
    errdefer client.allocator.destroy(result);

    result.request = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .headers = .{
            .user_agent = .{ .override = std.fmt.comptimePrint("{s}/{s}", .{ NAME, options.version }) },
        },
    });
    const request = &result.request;
    errdefer request.deinit();
    const redirect_buffer: []u8 = client.allocator.alloc(u8, 8 * 1024) catch blk: {
        request.redirect_behavior = .not_allowed;
        break :blk &.{};
    };
    defer client.allocator.free(redirect_buffer);

    request.sendBodiless() catch |err| switch (err) {
        error.WriteFailed => return request.connection.?.stream_writer.err.?,
    };
    const response = request.receiveHead(redirect_buffer) catch |err| switch (err) {
        error.ReadFailed => return request.connection.?.getReadError().?,
        error.RedirectRequiresResend => unreachable,
        error.WriteFailed => return request.connection.?.stream_writer.err.?,
        else => |e| return e,
    };
    if (response.head.status != .ok) return error.BadResponse;

    result.decompress_buffer = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    errdefer client.allocator.free(result.decompress_buffer);
    result.reader = request.reader.bodyReaderDecompressing(
        &result.transfer_buffer,
        response.head.transfer_encoding,
        response.head.content_length,
        response.head.content_encoding,
        &result.decompress,
        result.decompress_buffer,
    );

    return result;
}

pub fn fetchToFile(client: *Client, uri: std.Uri, writer: *std.Io.File.Writer) !void {
    const result = try fetch(client, uri);
    defer result.deinit();
    _ = result.reader.streamRemaining(&writer.interface) catch |err| switch (err) {
        error.ReadFailed => return result.getReadErr(),
        error.WriteFailed => return writer.err.?,
    };
    try writer.end();
}

/// Fetches and returns the signature for the tarball from the given mirror.
fn fetchSignature(
    allocator: std.mem.Allocator,
    client: *Client,
    mirror_url: []const u8,
    tarball_name: []const u8,
) !minizign.Signature {
    var url_buf: [MAX_MIRROR_URL_LEN]u8 = undefined;
    const url = try std.mem.print(&url_buf, "{s}/{s}.minisig", .{ mirror_url, tarball_name });
    var uri = try std.Uri.parse(url);
    uri.query = .{ .percent_encoded = "source=" ++ NAME };

    // Signatures are usually a few hundred bytes, but use 4KiB just in case.
    // Anything bigger is an error.
    var signature_buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&signature_buf);
    const result = try fetch(client, uri);
    defer result.deinit();
    _ = result.reader.streamRemaining(&writer) catch |err| switch (err) {
        error.ReadFailed => return result.getReadErr(),
        error.WriteFailed => return error.SignatureTooBig,
    };

    var signature: minizign.Signature = try .decode(allocator, writer.buffered());
    errdefer signature.deinit();
    // There's definitely enough space here as more space was used in printing the url
    const expected_file = std.mem.print(&url_buf, "\tfile:{s}\t", .{tarball_name}) catch unreachable;
    if (!std.mem.containsAtLeast(u8, signature.trusted_comment, 1, expected_file)) {
        log.warn(
            \\Bad trusted comment from mirror '{s}': {s}
            \\         The mirror or your connection may be compromised.
        , .{ mirror_url, signature.trusted_comment });
        return error.SignatureVerificationFailed;
    }
    return signature;
}

const DownloadProgress = struct {
    io: std.Io,
    start_t: std.Io.Timestamp,
    downloaded: u64 = 0,
    total: u64,

    pub fn start(io: std.Io, total: u64) DownloadProgress {
        return DownloadProgress{
            .io = io,
            .start_t = .now(io, .real),
            .total = total,
        };
    }

    pub fn writeProgress(self: DownloadProgress, stdout: *std.Io.Writer, last: bool) !void {
        const CLEAR_LINE = "\r\x1b[K";
        const dur = self.start_t.untilNow(self.io, .real);
        const bytes_per_s: u64 = @intCast(std.time.ns_per_s * @as(u96, self.downloaded) / @max(1, dur.nanoseconds));
        try stdout.print(
            CLEAR_LINE ++ "Downloaded {B: >8.2} of {B:.2} ({B:.2}/s)",
            .{ self.downloaded, self.total, bytes_per_s },
        );
        if (last) try stdout.writeByte('\n');
        try stdout.flush();
    }
};

/// Fetches the tarball from the given mirror, writing it to `writer`.
/// Download progress is printed to `stdout`.
fn fetchZigTarball(
    client: *Client,
    mirror_url: []const u8,
    tarball: files.TarballInfo,
    writer: *std.Io.Writer,
    stdout: *std.Io.Writer,
) !void {
    var url_buf: [MAX_MIRROR_URL_LEN]u8 = undefined;
    // We know this will parse correctly because it ran sucessfully earlier in fetchSignature()
    const url = std.mem.print(&url_buf, "{s}/{s}", .{ mirror_url, tarball.name }) catch unreachable;
    var uri = std.Uri.parse(url) catch unreachable;
    uri.query = .{ .percent_encoded = "source=" ++ NAME };

    const result = try fetch(client, uri);
    defer result.deinit();

    var progress: DownloadProgress = .start(client.io, tarball.size);
    while (true) {
        progress.downloaded += result.reader.stream(writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return result.getReadErr(),
            error.WriteFailed => |e| return e,
        };
        progress.writeProgress(stdout, false) catch {};
        if (progress.downloaded > tarball.size) return error.WrongSizeForTarball;
    }
    progress.writeProgress(stdout, true) catch {};
    if (progress.downloaded != tarball.size) return error.WrongSizeForTarball;
    try writer.flush();
}

/// If we get one of these errors while downloading from a mirror,
/// we will probably also get it while downloading from other mirrors.
fn isUnrecoverableError(err: anyerror) bool {
    switch (err) {
        error.SystemResources,
        error.WouldBlock,
        error.AccessDenied,
        error.Unexpected,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.NetworkDown,
        error.FastOpenAlreadyInProgress,
        error.OutOfMemory,
        error.AddressInUse,
        error.SocketModeUnsupported,
        error.OptionUnsupported,
        error.SocketNotBound,
        error.ResolvConfParseFailed,
        error.DetectingNetworkConfigurationFailed,
        error.CertificateBundleLoadFailure,
        => return true,
        else => return false,
    }
}

/// Fetches the tarball from the given mirror, writing it to `archive_file`.
/// If the signature does not match the downloaded file, returns an error.
/// Download progress is printed to `stdout`.
pub fn downloadZig(
    client: *Client,
    mirror_url: []const u8,
    tarball_info: files.TarballInfo,
    archive_file: std.Io.File,
    stdout: *std.Io.Writer,
) !void {
    const allocator = client.allocator;
    const io = client.io;

    log.info("Fetching signature...", .{});
    var signature = fetchSignature(allocator, client, mirror_url, tarball_info.name) catch |err| {
        if (isUnrecoverableError(err)) {
            fatal("Unable to download signature: {t}", .{err});
        } else {
            log.warn("Failed to download signature from '{s}': {t}", .{ mirror_url, err });
            return err;
        }
    };
    defer signature.deinit();

    var fw = archive_file.writer(io, &.{});
    log.info("Fetching zig tarball...", .{});
    fetchZigTarball(client, mirror_url, tarball_info, &fw.interface, stdout) catch |err| {
        if (isUnrecoverableError(err)) {
            fatal("Unable to download zig tarball: {t}", .{err});
        } else if (err == error.WriteFailed) {
            fatal("Unable to write to tarball file: {t}", .{fw.err.?});
        } else {
            log.warn("Failed to download zig tarball from '{s}': {t}", .{ mirror_url, err });
            fw.seekTo(0) catch |e| fatal("Failed to seek in tarball file: {t}", .{switch (e) {
                error.WriteFailed => fw.err.?,
                else => e,
            }});
            return err;
        }
    };
    fw.end() catch |err| fatal("Failed to write to file: {t}", .{switch (err) {
        error.WriteFailed => fw.err.?,
        else => err,
    }});
    fw.seekTo(0) catch |err| fatal("Failed to seek in tarball file: {t}", .{switch (err) {
        error.WriteFailed => fw.err.?,
        else => err,
    }});

    log.info("Verifying minisign signature...", .{});
    MINISIGN_KEY.verifyFile(allocator, io, archive_file, signature, null) catch |err| switch (err) {
        error.KeyIdMismatch,
        error.IdentityElement,
        error.InvalidEncoding,
        error.NonCanonical,
        error.SignatureVerificationFailed,
        error.UnsupportedAlgorithm,
        => {
            log.warn(
                \\Failed to verify signature of tarball downloaded from {s}
                \\         The mirror or your connection may be compromised.
            , .{mirror_url});
            return err;
        },
        error.OutOfMemory => {
            fatal("Out of memory", .{});
        },
        error.WeakPublicKey => {
            const REPO_URL = "https://codeberg.org/TemariVirus/zxc";
            fatal("Weak public key. Please file an issue at " ++ REPO_URL ++ " as this should never happen.", .{});
        },
        error.ReadFailed => {
            fatal("Unable to read downloaded tarball.", .{});
        },
    };
}
