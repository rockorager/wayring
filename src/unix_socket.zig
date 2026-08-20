//! Minimal Unix-socket setup for Wayland transports.
//!
//! Socket I/O remains owned by the io_uring reactor. These helpers only create,
//! connect, bind, and configure descriptors before reactor admission.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    InvalidPath,
    PathTooLong,
    AddressInUse,
    NotFound,
    PermissionDenied,
    BufferTooSmall,
    SystemCallFailed,
};

pub const Credentials = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

const Address = struct {
    value: linux.sockaddr.un,
    len: linux.socklen_t,

    fn init(path: []const u8) Error!Address {
        var value: linux.sockaddr.un = .{ .path = undefined };
        @memset(&value.path, 0);
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
            return error.InvalidPath;
        if (path.len >= value.path.len) return error.PathTooLong;
        @memcpy(value.path[0..path.len], path);
        return .{
            .value = value,
            .len = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1),
        };
    }
};

/// Resolves WAYLAND_DISPLAY-style names without allocating. Absolute display
/// names are copied directly; relative names are placed under XDG_RUNTIME_DIR.
pub fn resolveDisplayPath(
    storage: []u8,
    runtime_directory: []const u8,
    display_name: []const u8,
) Error![]const u8 {
    if (display_name.len == 0 or std.mem.indexOfScalar(u8, display_name, 0) != null)
        return error.InvalidPath;
    const required = if (display_name[0] == '/')
        display_name.len
    else blk: {
        if (runtime_directory.len == 0 or
            std.mem.indexOfScalar(u8, runtime_directory, 0) != null)
            return error.InvalidPath;
        const prefix_len = std.math.add(usize, runtime_directory.len, 1) catch
            return error.PathTooLong;
        break :blk std.math.add(usize, prefix_len, display_name.len) catch
            return error.PathTooLong;
    };
    if (required > storage.len) return error.BufferTooSmall;
    if (display_name[0] == '/') {
        @memcpy(storage[0..required], display_name);
    } else {
        @memcpy(storage[0..runtime_directory.len], runtime_directory);
        storage[runtime_directory.len] = '/';
        @memcpy(storage[runtime_directory.len + 1 .. required], display_name);
    }
    const path = storage[0..required];
    _ = try Address.init(path);
    return path;
}

/// Opens a connected close-on-exec, nonblocking Unix stream. Connection setup
/// itself is blocking so successful return always means the peer is connected.
pub fn connect(path: []const u8) Error!linux.fd_t {
    var address = try Address.init(path);
    const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try check(socket_result);
    const fd: linux.fd_t = @intCast(socket_result);
    errdefer _ = linux.close(fd);
    try check(linux.connect(fd, &address.value, address.len));
    try configure(fd);
    return fd;
}

/// Binds a close-on-exec, nonblocking Unix stream listener without unlinking an
/// existing path. The caller retains path cleanup policy and descriptor ownership.
pub fn listen(path: []const u8, backlog: u32) Error!linux.fd_t {
    var address = try Address.init(path);
    const socket_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    try check(socket_result);
    const fd: linux.fd_t = @intCast(socket_result);
    errdefer _ = linux.close(fd);
    try check(linux.bind(fd, @ptrCast(&address.value), address.len));
    errdefer unlink(path) catch {};
    try check(linux.listen(fd, backlog));
    return fd;
}

/// Removes a filesystem socket path. This is deliberately separate from close:
/// callers decide when replacing or shutting down a public display name is safe.
pub fn unlink(path: []const u8) Error!void {
    var address = try Address.init(path);
    try check(linux.unlink(@ptrCast(&address.value.path)));
}

/// Configures a connected descriptor supplied by the caller or inherited via
/// WAYLAND_SOCKET. Ownership does not transfer unless reactor attachment follows.
pub fn configure(fd: linux.fd_t) Error!void {
    const descriptor_flags = linux.fcntl(fd, linux.F.GETFD, 0);
    try check(descriptor_flags);
    try check(linux.fcntl(
        fd,
        linux.F.SETFD,
        descriptor_flags | linux.FD_CLOEXEC,
    ));
    try setNonblocking(fd);
}

/// Reads kernel-authenticated credentials for the process on the other end of
/// a connected Unix socket. No credential message or ancillary buffer is needed.
pub fn peerCredentials(fd: linux.fd_t) Error!Credentials {
    var credentials: Credentials = undefined;
    var len: linux.socklen_t = @sizeOf(Credentials);
    try check(linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        @ptrCast(&credentials),
        &len,
    ));
    if (len != @sizeOf(Credentials)) return error.SystemCallFailed;
    return credentials;
}

fn setNonblocking(fd: linux.fd_t) Error!void {
    const status = linux.fcntl(fd, linux.F.GETFL, 0);
    try check(status);
    const nonblocking: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    try check(linux.fcntl(fd, linux.F.SETFL, status | nonblocking));
}

fn check(result: usize) Error!void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        .ADDRINUSE => error.AddressInUse,
        .NOENT => error.NotFound,
        .ACCES, .PERM => error.PermissionDenied,
        else => error.SystemCallFailed,
    };
}

test "connects a nonblocking client to a filesystem listener" {
    var path_storage: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "/tmp/wayring-socket-test-{d}",
        .{linux.getpid()},
    );
    unlink(path) catch |err| if (err != error.NotFound) return err;
    defer unlink(path) catch {};

    const listener = try listen(path, 1);
    defer _ = linux.close(listener);
    try std.testing.expectError(error.AddressInUse, listen(path, 1));
    const client = try connect(path);
    defer _ = linux.close(client);
    const accepted_result = linux.accept4(
        listener,
        null,
        null,
        linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
    );
    try check(accepted_result);
    const accepted: linux.fd_t = @intCast(accepted_result);
    defer _ = linux.close(accepted);

    const status_result = linux.fcntl(client, linux.F.GETFL, 0);
    try check(status_result);
    const status: linux.O = @bitCast(@as(u32, @intCast(status_result)));
    try std.testing.expect(status.NONBLOCK);
    const descriptor_flags = linux.fcntl(client, linux.F.GETFD, 0);
    try check(descriptor_flags);
    try std.testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);
    const credentials = try peerCredentials(accepted);
    try std.testing.expectEqual(@as(i32, @intCast(linux.getpid())), credentials.pid);
    try std.testing.expectEqual(linux.getuid(), credentials.uid);
    try std.testing.expectEqual(linux.getgid(), credentials.gid);
    const payload = "wayring";
    try std.testing.expectEqual(payload.len, linux.write(client, payload.ptr, payload.len));
    var received: [payload.len]u8 = undefined;
    try std.testing.expectEqual(received.len, linux.read(accepted, &received, received.len));
    try std.testing.expectEqualSlices(u8, payload, &received);
}

test "rejects invalid Unix paths before creating a descriptor" {
    try std.testing.expectError(error.InvalidPath, connect(""));
    try std.testing.expectError(error.InvalidPath, connect("bad\x00path"));
    var oversized: [108]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(error.PathTooLong, listen(&oversized, 1));
}

test "resolves relative and absolute Wayland display paths" {
    var storage: [108]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/run/user/1000/wayland-2",
        try resolveDisplayPath(&storage, "/run/user/1000", "wayland-2"),
    );
    try std.testing.expectEqualStrings(
        "/tmp/custom-wayland",
        try resolveDisplayPath(&storage, "", "/tmp/custom-wayland"),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        resolveDisplayPath(storage[0..4], "/tmp", "wayland-0"),
    );
}
