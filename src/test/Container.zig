const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Child = std.process.Child;
const assert = std.debug.assert;

const Container = @This();
pub const SpawnOptions = std.process.SpawnOptions;

const dead: Container = .{ .id = null };

/// After `wait` or `kill` is called, this becomes `null`.
id: ?Child.Id,
/// The writing end of the process's standard input pipe.
stdin: ?File = null,
/// The reading end of the process's standard output pipe.
stdout: ?File = null,
/// The reading end of the process's standard error pipe.
stderr: ?File = null,

/// Spawns a process in a new namespace, with:
/// - no network access
/// - new PID namespace
/// - root mounted on `options.cwd`
pub fn spawn(gpa: Allocator, io: Io, options: SpawnOptions) Impl.SpawnError!Container {
    return Impl.spawn(gpa, io, options);
}

/// Waits for the container process to terminate and frees resources on success.
/// Cannot be called after a successfull call to `wait()` or `kill()`.
pub fn wait(self: *Container) Impl.WaitError!Child.Term {
    return Impl.wait(self);
}

/// Kills the container process and frees resources.
/// This function is idempotent and may be called after `wait()` or `kill()`.
pub fn kill(self: *Container) void {
    return Impl.kill(self);
}

const Impl = switch (@import("builtin").target.os.tag) {
    .linux => Linux,
    else => @compileError("Unsupported OS"),
};

const Linux = struct {
    const linux = std.os.linux;

    const ForkError = error{ SystemResources, OperationUnsupported, Unexpected };
    fn fork() ForkError!linux.pid_t {
        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .NOMEM, .AGAIN => return ForkError.SystemResources,
            .NOSYS => return ForkError.OperationUnsupported,
            else => return ForkError.Unexpected,
        }
    }

    const UnshareError = error{ Invalid, SystemResources, NoSpace, PermissionDenied, Unexpected };
    fn unshare(flags: usize) UnshareError!void {
        const rc = linux.unshare(flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INVAL => return UnshareError.Invalid,
            .NOMEM => return UnshareError.SystemResources,
            .NOSPC, .USERS => return UnshareError.NoSpace,
            .PERM => return UnshareError.PermissionDenied,
            else => return UnshareError.Unexpected,
        }
    }

    const MountError = error{
        AccessDenied,
        DeviceBusy,
        Invalid,
        SymLinkLoop,
        NameTooLong,
        FileNotFound,
        SystemResources,
        NotDir,
        PermissionDenied,
        Unexpected,
    };
    fn mount(
        source: ?[*:0]const u8,
        target: [*:0]const u8,
        fstype: ?[*:0]const u8,
        flags: u32,
        data: ?*anyopaque,
    ) MountError!void {
        const rc = linux.mount(source, target, fstype, flags, @intFromPtr(data));
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .ACCES, .ROFS => return MountError.AccessDenied,
            .BUSY => return MountError.DeviceBusy,
            .FAULT, .INVAL, .NOTBLK, .NXIO => return MountError.Invalid,
            .LOOP => return MountError.SymLinkLoop,
            .NAMETOOLONG => return MountError.NameTooLong,
            .NOENT => return MountError.FileNotFound,
            .NOMEM, .NOSPC => return MountError.SystemResources,
            .NOTDIR => return MountError.NotDir,
            .PERM => return MountError.PermissionDenied,
            else => return MountError.Unexpected,
        }
    }

    const UnmountError = error{
        DeviceBusy,
        Invalid,
        NameTooLong,
        FileNotFound,
        SystemResources,
        PermissionDenied,
        Unexpected,
    };
    fn umount2(target: [*:0]const u8, flags: u32) UnmountError!void {
        const rc = linux.umount2(target, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .BUSY => return UnmountError.DeviceBusy,
            .AGAIN, .FAULT, .INVAL => return UnmountError.Invalid,
            .NAMETOOLONG => return UnmountError.NameTooLong,
            .NOENT => return UnmountError.FileNotFound,
            .NOMEM => return UnmountError.SystemResources,
            .PERM => return UnmountError.PermissionDenied,
            else => return UnmountError.Unexpected,
        }
    }

    const PivotRootError = error{ DeviceBusy, Invalid, NotDir, PermissionDenied, Unexpected };
    fn pivotRoot(new_root: [*:0]const u8, put_old: [*:0]const u8) PivotRootError!void {
        const rc = linux.pivot_root(new_root, put_old);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .BUSY => return PivotRootError.DeviceBusy,
            .INVAL => return PivotRootError.Invalid,
            .NOTDIR => return PivotRootError.NotDir,
            .PERM => return PivotRootError.PermissionDenied,
            else => return PivotRootError.Unexpected,
        }
    }

    const PipeError = error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected };
    fn pipe2(flags: std.posix.O) PipeError![2]linux.fd_t {
        var fd: [2]linux.fd_t = undefined;
        const rc = std.posix.system.pipe2(&fd, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return fd,
            .MFILE => return PipeError.ProcessFdQuotaExceeded,
            .NFILE => return PipeError.SystemFdQuotaExceeded,
            else => return PipeError.Unexpected,
        }
    }

    const DupError = error{ FileNotOpen, FileBusy, ProcessFdQuotaExceeded, Unexpected };
    fn dup2(old: linux.fd_t, new: linux.fd_t) DupError!void {
        if (old == new) return; // Old fd already matches

        while (true) {
            const rc = linux.dup2(old, new);
            switch (linux.errno(rc)) {
                .SUCCESS => return,
                .BADF => return DupError.FileNotOpen,
                .BUSY => return DupError.FileBusy,
                .INTR => continue,
                .MFILE => return DupError.ProcessFdQuotaExceeded,
                else => return DupError.Unexpected,
            }
        }
    }

    fn close(fd: linux.fd_t) void {
        while (true) {
            const rc = linux.close(fd);
            switch (linux.errno(rc)) {
                .INTR => continue,
                else => break,
            }
        }
    }

    const ExecveError = Allocator.Error || error{
        FileTooBig,
        AccessDenied,
        ResourceLimitReached,
        Invalid,
        InvalidExe,
        InputOutput,
        SymLinkLoop,
        ProcessFdQuotaExceeded,
        NameTooLong,
        SystemFdQuotaExceeded,
        FileNotFound,
        SystemResources,
        PermissionDenied,
        FileBusy,
        Unexpected,
    };
    fn execve(
        gpa: Allocator,
        argv: []const []const u8,
        env_map: ?*const std.process.Environ.Map,
    ) ExecveError!noreturn {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const argvz = try arena.allocator().allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, argvz) |v, *vz| {
            vz.* = try arena.allocator().dupeSentinel(u8, v, 0);
        }
        const envp: std.process.Environ.PosixBlock = if (env_map) |em|
            try em.createPosixBlock(arena.allocator(), .{})
        else
            .{ .slice = &.{} };

        const rc = linux.execve(argvz[0].?, argvz, envp.slice);
        switch (linux.errno(rc)) {
            .SUCCESS => unreachable,
            .@"2BIG" => return ExecveError.FileTooBig,
            .ACCES => return ExecveError.AccessDenied,
            .AGAIN => return ExecveError.ResourceLimitReached,
            .FAULT => return ExecveError.Invalid,
            .INVAL, .ISDIR, .LIBBAD, .NOEXEC => return ExecveError.InvalidExe,
            .IO => return ExecveError.InputOutput,
            .LOOP => return ExecveError.SymLinkLoop,
            .MFILE => return ExecveError.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return ExecveError.NameTooLong,
            .NFILE => return ExecveError.SystemFdQuotaExceeded,
            .NOENT, .NOTDIR => return ExecveError.FileNotFound,
            .NOMEM => return ExecveError.SystemResources,
            .PERM => return ExecveError.PermissionDenied,
            .TXTBSY => return ExecveError.FileBusy,
            else => return ExecveError.Unexpected,
        }
    }

    const WaitpidError = error{ Invalid, Unexpected };
    fn waitpid(pid: linux.pid_t, flags: u32) WaitpidError!u32 {
        var status: i32 = undefined;
        while (true) {
            const rc = linux.waitpid(pid, &status, flags);
            switch (linux.errno(rc)) {
                .SUCCESS => return @bitCast(status),
                .CHILD => return 0xFFFF_FF7E, // Unknown termination status
                .INTR => continue,
                .INVAL => return WaitpidError.Invalid,
                else => return WaitpidError.Unexpected,
            }
        }
    }

    const KillError = error{ PermissionDenied, Unexpected };
    fn sys_kill(pid: linux.pid_t, sig: linux.SIG) KillError!void {
        const rc = linux.kill(pid, sig);
        switch (linux.errno(rc)) {
            .SUCCESS, .SRCH => return,
            .PERM => return KillError.PermissionDenied,
            else => return KillError.Unexpected,
        }
    }

    fn setupIdMaps(io: Io, uid: u32, gid: u32) (File.OpenError || File.Writer.Error)!void {
        var buf: [15]u8 = undefined;

        {
            const f = try Dir.openFileAbsolute(io, "/proc/self/setgroups", .{ .mode = .write_only });
            defer f.close(io);
            try f.writeStreamingAll(io, "deny\n");
        }
        {
            const f = try Dir.openFileAbsolute(io, "/proc/self/uid_map", .{ .mode = .write_only });
            defer f.close(io);
            const bytes = std.fmt.bufPrint(&buf, "0 {d} 1\n", .{uid}) catch unreachable;
            try f.writeStreamingAll(io, bytes);
        }
        {
            const f = try Dir.openFileAbsolute(io, "/proc/self/gid_map", .{ .mode = .write_only });
            defer f.close(io);
            const bytes = std.fmt.bufPrint(&buf, "0 {d} 1\n", .{gid}) catch unreachable;
            try f.writeStreamingAll(io, bytes);
        }
    }

    fn createPipe(stdio: SpawnOptions.StdIo) PipeError!?[2]linux.fd_t {
        return switch (stdio) {
            .inherit, .file, .ignore, .close => null,
            .pipe => try pipe2(.{}),
        };
    }

    fn setupChildStdio(
        stdio: SpawnOptions.StdIo,
        stdio_fd: linux.fd_t,
        dev_null: ?File,
        stdio_pipe: ?[2]linux.fd_t,
    ) DupError!void {
        const pipe_idx: usize = switch (stdio_fd) {
            linux.STDIN_FILENO => 0,
            linux.STDOUT_FILENO, linux.STDERR_FILENO => 1,
            else => unreachable,
        };

        switch (stdio) {
            .inherit => {},
            .file => |f| try dup2(f.handle, stdio_fd),
            .ignore => try dup2(dev_null.?.handle, stdio_fd),
            .pipe => {
                try dup2(stdio_pipe.?[pipe_idx], stdio_fd);
                close(stdio_pipe.?[0]);
                close(stdio_pipe.?[1]);
            },
            .close => close(stdio_fd),
        }
    }

    fn closeIfNotStdio(io: Io, f: File) void {
        switch (f.handle) {
            linux.STDIN_FILENO, linux.STDOUT_FILENO, linux.STDERR_FILENO => {},
            else => f.close(io),
        }
    }

    fn fileFromFd(fd: linux.fd_t) File {
        return .{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };
    }

    fn spawnChild(
        gpa: Allocator,
        io: std.Io,
        options: SpawnOptions,
        stdin_pipe: ?[2]linux.fd_t,
        stdout_pipe: ?[2]linux.fd_t,
        stderr_pipe: ?[2]linux.fd_t,
    ) SpawnError!noreturn {
        const uid = options.uid orelse linux.getuid();
        const gid = options.gid orelse linux.getgid();
        var root_buf: [Dir.max_path_bytes + 1]u8 = undefined;
        const root_len = switch (options.cwd) {
            .inherit => try std.process.currentPath(io, &root_buf),
            .dir => |dir| try dir.realPath(io, &root_buf),
            .path => |path| try Dir.realPathFile(.cwd(), io, path, &root_buf),
        };
        root_buf[root_len] = 0;
        const root: [*:0]const u8 = @ptrCast(root_buf[0 .. root_len + 1]);

        // Create namespace
        try unshare(linux.CLONE.NEWUSER |
            linux.CLONE.NEWNS |
            linux.CLONE.NEWNET);
        // Write uid and gid maps
        try setupIdMaps(io, uid, gid);

        // /dev/null must be opened before calling pivotRoot()
        const dev_null = if (options.stdin == .ignore or options.stdout == .ignore or options.stderr == .ignore)
            try Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write })
        else
            null;

        // Bind mount root to itself as pivotRoot() requires a mount point
        try mount(root, root, null, linux.MS.BIND | linux.MS.REC, null);
        // Set new root
        try std.process.setCurrentPath(io, root_buf[0..root_len]);
        try pivotRoot(".", ".");
        // Ensure old root is private so unmounts do not propagate outside new root
        try mount(".", ".", null, linux.MS.REC | linux.MS.PRIVATE, null);
        // Unmount old root
        try umount2(".", linux.MNT.DETACH);
        // cd to cwd in new root
        try std.process.setCurrentPath(io, "/");

        // Set up stdin, stdout, stderr
        try setupChildStdio(options.stdin, linux.STDIN_FILENO, dev_null, stdin_pipe);
        try setupChildStdio(options.stdout, linux.STDOUT_FILENO, dev_null, stdout_pipe);
        try setupChildStdio(options.stderr, linux.STDERR_FILENO, dev_null, stderr_pipe);
        if (dev_null) |f| f.close(io);
        switch (options.stdin) {
            .file => |f| closeIfNotStdio(io, f),
            else => {},
        }
        switch (options.stdout) {
            .file => |f| closeIfNotStdio(io, f),
            else => {},
        }
        switch (options.stderr) {
            .file => |f| closeIfNotStdio(io, f),
            else => {},
        }

        try execve(gpa, options.argv, options.environ_map);
    }

    pub const SpawnError = ForkError || UnshareError || MountError || UnmountError ||
        PivotRootError || PipeError || DupError || ExecveError ||
        Dir.RealPathError || Dir.RealPathFileError || File.OpenError || File.Writer.Error ||
        Allocator.Error || std.process.CurrentPathError || std.process.SetCurrentPathError;
    pub fn spawn(gpa: Allocator, io: Io, options: SpawnOptions) SpawnError!Container {
        assert(options.argv.len > 0);
        // Unsupported options
        assert(options.exe == .detect);
        assert(options.expand_arg0 == .no_expand);
        assert(options.progress_node.index == .none);
        assert(options.inherit_dirs.len == 0);
        assert(options.inherit_files.len == 0);
        assert(!options.request_resource_usage_statistics);
        assert(!options.start_suspended);

        const ErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));

        const stdin_pipe = try createPipe(options.stdin);
        errdefer if (stdin_pipe) |fds| {
            for (fds) |fd| close(fd);
        };
        const stdout_pipe = try createPipe(options.stdout);
        errdefer if (stdout_pipe) |fds| {
            for (fds) |fd| close(fd);
        };
        const stderr_pipe = try createPipe(options.stderr);
        errdefer if (stderr_pipe) |fds| {
            for (fds) |fd| close(fd);
        };
        const err_pipe = try pipe2(.{ .CLOEXEC = true });
        defer for (err_pipe) |fd| close(fd);

        const pid = try fork();
        if (pid == 0) {
            // We are the child
            defer std.process.exit(1); // Kill ourselves on failure
            close(err_pipe[0]);
            spawnChild(gpa, io, options, stdin_pipe, stdout_pipe, stderr_pipe) catch |err| {
                if (@errorReturnTrace()) |et| {
                    std.debug.dumpErrorReturnTrace(et);
                }
                const err_f = fileFromFd(err_pipe[1]);
                var err_buf: [8]u8 = undefined;
                var err_w = err_f.writerStreaming(io, &err_buf);
                err_w.interface.writeInt(ErrorInt, @intFromError(err), .native) catch {};
                err_w.interface.flush() catch {};
            };
        }

        // We are the parent
        const err_no = err: {
            errdefer comptime unreachable;
            var child: Container = .{
                .id = pid,
            };
            if (stdin_pipe) |fds| {
                close(fds[0]);
                child.stdin = fileFromFd(fds[1]);
            }
            if (stdout_pipe) |fds| {
                close(fds[1]);
                child.stdout = fileFromFd(fds[0]);
            }
            if (stderr_pipe) |fds| {
                close(fds[1]);
                child.stderr = fileFromFd(fds[0]);
            }

            close(err_pipe[1]);
            const err_f = fileFromFd(err_pipe[0]);
            var err_buf: [8]u8 = undefined;
            var err_r = err_f.readerStreaming(io, &err_buf);
            break :err err_r.interface.takeInt(ErrorInt, .native) catch return child;
        };
        return @errorCast(@errorFromInt(err_no));
    }

    fn cleanup(proc: *const Container) void {
        if (proc.stdin) |f| {
            close(f.handle);
        }
        if (proc.stdout) |f| {
            close(f.handle);
        }
        if (proc.stderr) |f| {
            close(f.handle);
        }
    }

    pub const WaitError = error{Unexpected};
    pub fn wait(proc: *Container) WaitError!Child.Term {
        const status = waitpid(proc.id.?, 0) catch |err| switch (err) {
            WaitpidError.Invalid => unreachable,
            WaitpidError.Unexpected => |e| return e,
        };
        cleanup(proc);
        proc.* = .dead;

        if (linux.W.IFEXITED(status)) {
            return .{ .exited = linux.W.EXITSTATUS(status) };
        }
        if (linux.W.IFSIGNALED(status)) {
            return .{ .signal = linux.W.TERMSIG(status) };
        }
        if (linux.W.IFSTOPPED(status)) {
            return .{ .stopped = linux.W.STOPSIG(status) };
        }
        return .{ .unknown = status };
    }

    pub fn kill(proc: *Container) void {
        if (proc.id) |id| {
            sys_kill(id, .KILL) catch {};
        }
        cleanup(proc);
        proc.* = .dead;
    }
};
