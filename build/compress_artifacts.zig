const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const compress_buf = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(compress_buf);
    // TODO: support .tar.xz and .zip, instead of .tar.gz
    var compress: std.compress.flate.Compress = try .init(&stdout.interface, compress_buf, .gzip, .level_9);

    var tar: std.tar.Writer = .{ .underlying_writer = &compress.writer };

    const read_buf = try gpa.alloc(u8, compress_buf.len);
    defer gpa.free(read_buf);
    for (args[1..]) |arg| {
        const out_path = std.Io.Dir.path.basename(arg);
        const file = try std.Io.Dir.openFile(.cwd(), io, arg, .{});
        defer file.close(io);
        var reader = file.reader(io, read_buf);

        try tar.writeFileStream(
            out_path,
            try reader.getSize(),
            &reader.interface,
            .{ .mode = 0o755 },
        );
    }

    try compress.finish();
    try stdout.flush();
}
