//! Ordered ownership of file descriptors received through SCM_RIGHTS.

const std = @import("std");
const linux = std.os.linux;
const pools = @import("pool.zig");

pub const Error = pools.Error || error{
    MalformedControl,
    DescriptorBudgetExceeded,
    ControlBufferTooSmall,
    Overflow,
    Empty,
};

/// A byte-budgeted FIFO. Descriptors in the queue are owned by the queue until
/// removed with `pop`; shared backing storage grows on demand.
pub const FdQueue = struct {
    pool: *pools.SharedFds,
    budget: usize,
    head: ?pools.FdLease = null,
    tail: ?pools.FdLease = null,
    count: usize = 0,

    pub fn init(pool: *pools.SharedFds, budget: usize) FdQueue {
        return .{ .pool = pool, .budget = budget };
    }

    pub fn deinit(queue: *FdQueue) void {
        while (queue.pop()) |fd| {
            _ = linux.close(fd);
        } else |_| {}
    }

    pub fn len(queue: FdQueue) usize {
        return queue.count;
    }

    pub fn available(queue: FdQueue) usize {
        return queue.budget - queue.count;
    }

    pub fn ensureCapacity(queue: FdQueue, count: usize) Error!void {
        if (count > queue.available()) return error.DescriptorBudgetExceeded;
        try queue.pool.ensureAvailable(count);
    }

    /// Transfers ownership of the oldest descriptor to the caller.
    pub fn pop(queue: *FdQueue) Error!linux.fd_t {
        if (queue.count == 0) return error.Empty;
        const head = queue.head.?;
        queue.head = try queue.pool.nextLease(head);
        const fd = try queue.pool.take(head);
        queue.count -= 1;
        if (queue.head == null) queue.tail = null;
        return fd;
    }

    pub fn append(queue: *FdQueue, fd: linux.fd_t) Error!void {
        try queue.ensureCapacity(1);
        const lease = try queue.pool.acquire(fd);
        if (queue.tail) |tail| {
            queue.pool.link(tail, lease) catch |err| {
                _ = queue.pool.take(lease) catch unreachable;
                return err;
            };
        } else queue.head = lease;
        queue.tail = lease;
        queue.count += 1;
    }

    pub fn copyTo(queue: FdQueue, destination: []linux.fd_t) Error![]linux.fd_t {
        if (destination.len < queue.count) return error.DescriptorBudgetExceeded;
        var current = queue.head;
        var index: usize = 0;
        while (current) |lease| : (index += 1) {
            destination[index] = lease.fd;
            current = try queue.pool.nextLease(lease);
        }
        return destination[0..queue.count];
    }
};

/// Transfers every SCM_RIGHTS descriptor in `control` into `queue`, preserving
/// kernel delivery order. Unknown ancillary records are ignored.
pub fn enqueueRights(control: []const u8, queue: *FdQueue) Error!usize {
    errdefer closeRights(control) catch {};
    var count: usize = 0;
    var first_pass: RightsIterator = .{ .control = control };
    while (try first_pass.next() != null) count += 1;
    if (count == 0) return 0;

    try queue.ensureCapacity(count);

    var enqueue_pass: RightsIterator = .{ .control = control };
    while (try enqueue_pass.next()) |fd| queue.append(fd) catch unreachable;
    return count;
}

/// Closes received rights without queueing them. On malformed control, closes
/// the valid prefix before returning an error.
pub fn closeRights(control: []const u8) Error!void {
    var rights: RightsIterator = .{ .control = control };
    while (try rights.next()) |fd| _ = linux.close(fd);
}

/// Encodes one SCM_RIGHTS record. Sending duplicates the descriptors into the
/// receiver, so the caller retains ownership before and after the send.
pub fn encodeRights(storage: []u8, fds: []const linux.fd_t) Error![]const u8 {
    if (fds.len == 0) return error.MalformedControl;
    const space = try rightsControlSize(fds.len);
    if (storage.len < space) return error.ControlBufferTooSmall;
    @memset(storage[0..space], 0);

    const data_len = fds.len * @sizeOf(linux.fd_t);
    const used = cmsgDataOffset() + data_len;

    const header: linux.cmsghdr = .{
        .len = used,
        .level = linux.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    @memcpy(storage[0..@sizeOf(linux.cmsghdr)], std.mem.asBytes(&header));
    @memcpy(storage[cmsgDataOffset()..used], std.mem.sliceAsBytes(fds));
    return storage[0..space];
}

pub fn rightsControlSize(fd_count: usize) Error!usize {
    if (fd_count == 0) return 0;
    const data_len = std.math.mul(usize, fd_count, @sizeOf(linux.fd_t)) catch
        return error.Overflow;
    const used = std.math.add(usize, cmsgDataOffset(), data_len) catch
        return error.Overflow;
    return cmsgAlign(used) catch error.Overflow;
}

const RightsIterator = struct {
    control: []const u8,
    record_offset: usize = 0,
    rights: []const u8 = &.{},
    rights_offset: usize = 0,

    fn next(iterator: *RightsIterator) Error!?linux.fd_t {
        while (true) {
            if (iterator.rights_offset < iterator.rights.len) {
                const start = iterator.rights_offset;
                iterator.rights_offset += @sizeOf(linux.fd_t);
                return std.mem.bytesToValue(
                    linux.fd_t,
                    iterator.rights[start..][0..@sizeOf(linux.fd_t)],
                );
            }

            if (iterator.record_offset == iterator.control.len) return null;
            if (iterator.control.len - iterator.record_offset < @sizeOf(linux.cmsghdr))
                return error.MalformedControl;

            const record = iterator.control[iterator.record_offset..];
            const header = std.mem.bytesToValue(
                linux.cmsghdr,
                record[0..@sizeOf(linux.cmsghdr)],
            );
            if (header.len < cmsgDataOffset() or header.len > record.len)
                return error.MalformedControl;

            const aligned_len = cmsgAlign(header.len) catch return error.MalformedControl;
            if (aligned_len > record.len and header.len != record.len)
                return error.MalformedControl;
            iterator.record_offset += @min(aligned_len, record.len);

            if (header.level != linux.SOL.SOCKET or header.type != linux.SCM.RIGHTS)
                continue;

            const data = record[cmsgDataOffset()..header.len];
            if (data.len == 0 or data.len % @sizeOf(linux.fd_t) != 0)
                return error.MalformedControl;
            iterator.rights = data;
            iterator.rights_offset = 0;
        }
    }
};

fn cmsgDataOffset() usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) catch unreachable;
}

fn cmsgAlign(len: usize) error{Overflow}!usize {
    return std.mem.alignForward(usize, len, @sizeOf(usize));
}

fn rightsControl(storage: []u8, fds: []const linux.fd_t) []const u8 {
    return encodeRights(storage, fds) catch unreachable;
}

test "queues rights in order and wraps" {
    const allocator = std.testing.allocator;
    var pool = try pools.SharedFds.init(allocator, 3);
    defer pool.deinit(allocator);
    var queue = FdQueue.init(&pool, 3);
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;

    try std.testing.expectEqual(2, try enqueueRights(rightsControl(&control, &.{ 10, 11 }), &queue));
    try std.testing.expectEqual(@as(linux.fd_t, 10), try queue.pop());
    try std.testing.expectEqual(2, try enqueueRights(rightsControl(&control, &.{ 12, 13 }), &queue));
    try std.testing.expectEqual(@as(linux.fd_t, 11), try queue.pop());
    try std.testing.expectEqual(@as(linux.fd_t, 12), try queue.pop());
    try std.testing.expectEqual(@as(linux.fd_t, 13), try queue.pop());
    try std.testing.expectError(error.Empty, queue.pop());
}

test "rejects malformed rights records" {
    const allocator = std.testing.allocator;
    var pool = try pools.SharedFds.init(allocator, 1);
    defer pool.deinit(allocator);
    var queue = FdQueue.init(&pool, 1);
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const bytes = rightsControl(&control, &.{10});
    const header: *linux.cmsghdr = @ptrCast(@alignCast(control[0..].ptr));
    header.len -= 1;

    try std.testing.expectError(error.MalformedControl, enqueueRights(bytes, &queue));
}

test "malformed control closes rights from earlier records" {
    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[1]);
    var pool = try pools.SharedFds.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var queue = FdQueue.init(&pool, 1);
    defer queue.deinit();
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const valid = try encodeRights(&control, &.{sockets[0]});
    const end = valid.len + @sizeOf(linux.cmsghdr);
    @memset(control[valid.len..end], 0);
    try std.testing.expectError(error.MalformedControl, enqueueRights(control[0..end], &queue));
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(sockets[0], linux.F.GETFD, 0)));
}

test "receives real SCM_RIGHTS descriptors with close-on-exec" {
    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    const payload = [_]u8{42};
    var send_iov: std.posix.iovec_const = .{ .base = &payload, .len = payload.len };
    var send_control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const control = rightsControl(&send_control, &.{sockets[0]});
    const send_message: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&send_iov),
        .iovlen = 1,
        .control = control.ptr,
        .controllen = control.len,
        .flags = 0,
    };
    try std.testing.expectEqual(payload.len, try syscallLength(linux.sendmsg(sockets[0], &send_message, 0)));

    var received_payload: [1]u8 = undefined;
    var receive_iov: std.posix.iovec = .{ .base = &received_payload, .len = received_payload.len };
    var receive_control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var receive_message: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&receive_iov),
        .iovlen = 1,
        .control = &receive_control,
        .controllen = receive_control.len,
        .flags = 0,
    };
    try std.testing.expectEqual(payload.len, try syscallLength(linux.recvmsg(
        sockets[1],
        &receive_message,
        linux.MSG.CMSG_CLOEXEC,
    )));
    try std.testing.expectEqualSlices(u8, &payload, &received_payload);
    try std.testing.expectEqual(@as(u32, 0), receive_message.flags & linux.MSG.CTRUNC);

    const allocator = std.testing.allocator;
    var pool = try pools.SharedFds.init(allocator, 1);
    defer pool.deinit(allocator);
    var queue = FdQueue.init(&pool, 1);
    defer queue.deinit();
    try std.testing.expectEqual(1, try enqueueRights(receive_control[0..receive_message.controllen], &queue));

    const received_fd = try queue.pop();
    defer _ = linux.close(received_fd);
    const descriptor_flags = linux.fcntl(received_fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_flags));
    try std.testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);
}

fn syscallLength(result: usize) !usize {
    try expectSuccess(result);
    return result;
}

fn expectSuccess(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.UnexpectedSystemError;
}
