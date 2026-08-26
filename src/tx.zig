//! Byte-budgeted transmit queue backed by growable reactor-wide blocks.

const std = @import("std");
const linux = std.os.linux;
const ancillary = @import("ancillary.zig");
const pools = @import("pool.zig");

pub const Error = ancillary.Error || pools.Error || error{
    EmptyMessage,
    ByteBudgetExceeded,
    DescriptorBudgetExceeded,
    SendAlreadyActive,
    NoSendActive,
    InvalidCompletion,
    ReservationActive,
    ReservationOverflow,
};

pub const Snapshot = struct {
    first: []const u8,
    second: []const u8,
    control: []const u8,
    descriptor_count: usize,

    pub fn byteCount(snapshot: Snapshot) usize {
        return snapshot.first.len + snapshot.second.len;
    }
};

/// Bytes are stored in blocks shared by every connection on a reactor.
/// Connections retain only chain state and a logical byte budget. Descriptors
/// remain an independent ordered stream. Enqueue takes descriptor ownership
/// only after both streams have enough capacity.
pub const Queue = struct {
    const Flight = struct {
        byte_count: usize,
        descriptor_count: usize,
    };

    blocks: *pools.SharedBlocks,
    byte_budget: usize,
    head: ?pools.Lease = null,
    tail: ?pools.Lease = null,
    head_offset: usize = 0,
    tail_used: usize = 0,
    byte_count: usize = 0,
    descriptors: ancillary.FdQueue,
    active: ?Flight = null,
    reservation_active: bool = false,

    pub fn init(
        blocks: *pools.SharedBlocks,
        byte_budget: usize,
        descriptor_pool: *pools.SharedFds,
        descriptor_budget: usize,
    ) Queue {
        std.debug.assert(byte_budget > 0);
        return .{
            .blocks = blocks,
            .byte_budget = byte_budget,
            .descriptors = ancillary.FdQueue.init(descriptor_pool, descriptor_budget),
        };
    }

    pub fn deinit(queue: *Queue) void {
        std.debug.assert(!queue.reservation_active);
        while (queue.head) |head| {
            const next = queue.blocks.nextLease(head) catch unreachable;
            queue.blocks.release(head) catch unreachable;
            queue.head = next;
        }
        queue.descriptors.deinit();
        queue.tail = null;
        queue.byte_count = 0;
        queue.active = null;
    }

    pub fn queuedBytes(queue: Queue) usize {
        return queue.byte_count;
    }

    pub fn queuedDescriptors(queue: Queue) usize {
        return queue.descriptors.len();
    }

    pub fn sendActive(queue: Queue) bool {
        return queue.active != null;
    }

    pub fn enqueue(queue: *Queue, bytes: []const u8, descriptors: []const linux.fd_t) Error!void {
        if (bytes.len == 0) return error.EmptyMessage;
        try queue.ensureCapacity(bytes.len, descriptors.len);

        queue.appendBytes(bytes);
        for (descriptors) |fd| queue.descriptors.append(fd) catch unreachable;
    }

    /// Reserves aggregate queue and shared-pool capacity without publishing
    /// bytes. Synchronous callers may use this before committing several
    /// messages; no other queue or reactor operation may interleave before
    /// they finish.
    pub fn ensureCapacity(
        queue: *Queue,
        byte_count: usize,
        descriptor_count: usize,
    ) Error!void {
        if (queue.reservation_active) return error.ReservationActive;
        if (byte_count > queue.byte_budget - queue.byte_count)
            return error.ByteBudgetExceeded;
        try queue.descriptors.ensureCapacity(descriptor_count);

        const tail_space = if (queue.tail == null)
            0
        else
            queue.blocks.block_size - queue.tail_used;
        const bytes_needing_blocks = byte_count - @min(byte_count, tail_space);
        const blocks_needed = std.math.divCeil(
            usize,
            bytes_needing_blocks,
            queue.blocks.block_size,
        ) catch unreachable;
        try queue.blocks.ensureAvailable(blocks_needed);
    }

    /// Reserves private shared blocks without making bytes visible to snapshots.
    /// The reservation must be committed or aborted synchronously before any
    /// other operation on this queue.
    pub fn reserve(queue: *Queue, byte_count: usize) Error!Reservation {
        if (queue.reservation_active) return error.ReservationActive;
        if (byte_count == 0) return error.EmptyMessage;
        if (byte_count > queue.byte_budget - queue.byte_count)
            return error.ByteBudgetExceeded;

        const original_tail = queue.tail;
        const original_tail_used = queue.tail_used;
        const tail_space = if (original_tail == null)
            0
        else
            queue.blocks.block_size - original_tail_used;
        const new_bytes = byte_count - @min(byte_count, tail_space);
        const blocks_needed = std.math.divCeil(
            usize,
            new_bytes,
            queue.blocks.block_size,
        ) catch unreachable;
        try queue.blocks.ensureAvailable(blocks_needed);

        var new_head: ?pools.Lease = null;
        var new_tail: ?pools.Lease = null;
        errdefer releasePrivateChain(queue.blocks, new_head);
        for (0..blocks_needed) |_| {
            const block = try queue.blocks.acquire();
            if (new_tail) |tail| try queue.blocks.link(tail, block) else new_head = block;
            new_tail = block;
        }
        queue.reservation_active = true;
        return .{
            .queue = queue,
            .byte_count = byte_count,
            .original_tail = original_tail,
            .original_tail_used = original_tail_used,
            .tail_space = tail_space,
            .new_head = new_head,
            .new_tail = new_tail,
            .current_new = new_head,
            .final_tail_used = if (new_bytes == 0)
                original_tail_used + byte_count
            else if (new_bytes % queue.blocks.block_size == 0)
                queue.blocks.block_size
            else
                new_bytes % queue.blocks.block_size,
        };
    }

    /// Describes at most the first two blocks. Longer chains are drained by
    /// subsequent send SQEs, preserving bounded iovec storage.
    pub fn snapshot(
        queue: Queue,
        descriptor_scratch: []linux.fd_t,
        control_storage: []u8,
    ) Error!Snapshot {
        if (queue.reservation_active) return error.ReservationActive;
        const head = queue.head orelse return error.EmptyMessage;
        if (queue.descriptors.len() > descriptor_scratch.len)
            return error.DescriptorBudgetExceeded;

        const first_end = if (head.index == queue.tail.?.index)
            queue.tail_used
        else
            head.bytes.len;
        const first = head.bytes[queue.head_offset..first_end];
        var second: []const u8 = &.{};
        if (try queue.blocks.nextLease(head)) |next| {
            const second_end = if (next.index == queue.tail.?.index)
                queue.tail_used
            else
                next.bytes.len;
            second = next.bytes[0..second_end];
        }

        var control: []const u8 = &.{};
        if (queue.descriptors.len() > 0) {
            const copied = try queue.descriptors.copyTo(descriptor_scratch);
            control = try ancillary.encodeRights(
                control_storage,
                copied,
            );
        }
        return .{
            .first = first,
            .second = second,
            .control = control,
            .descriptor_count = queue.descriptors.len(),
        };
    }

    /// Appending remains valid while this immutable byte range is in flight.
    pub fn begin(queue: *Queue, snapshot_value: Snapshot) Error!void {
        if (queue.reservation_active) return error.ReservationActive;
        if (queue.sendActive()) return error.SendAlreadyActive;
        if (snapshot_value.byteCount() == 0 or snapshot_value.byteCount() > queue.byte_count or
            snapshot_value.descriptor_count > queue.descriptors.len())
            return error.InvalidCompletion;
        queue.active = .{
            .byte_count = snapshot_value.byteCount(),
            .descriptor_count = snapshot_value.descriptor_count,
        };
    }

    /// Partial writes consume only submitted bytes. SCM_RIGHTS descriptors are
    /// consumed after the first successful byte because the kernel has already
    /// transferred them.
    pub fn complete(queue: *Queue, written: usize) Error!void {
        if (queue.reservation_active) return error.ReservationActive;
        const active = queue.active orelse return error.NoSendActive;
        if (written == 0 or written > active.byte_count) return error.InvalidCompletion;

        var remaining = written;
        while (remaining > 0) {
            const head = queue.head orelse return error.InvalidCompletion;
            const end = if (head.index == queue.tail.?.index)
                queue.tail_used
            else
                head.bytes.len;
            const available = end - queue.head_offset;
            if (remaining < available) {
                queue.head_offset += remaining;
                remaining = 0;
            } else {
                remaining -= available;
                const next = try queue.blocks.nextLease(head);
                try queue.blocks.release(head);
                queue.head = next;
                queue.head_offset = 0;
                if (next == null) {
                    queue.tail = null;
                    queue.tail_used = 0;
                }
            }
        }
        queue.byte_count -= written;
        for (0..active.descriptor_count) |_| _ = linux.close(try queue.descriptors.pop());
        queue.active = null;
    }

    pub fn failed(queue: *Queue) Error!void {
        if (queue.reservation_active) return error.ReservationActive;
        if (!queue.sendActive()) return error.NoSendActive;
        queue.active = null;
    }

    fn appendBytes(queue: *Queue, bytes: []const u8) void {
        var remaining = bytes;
        while (remaining.len > 0) {
            if (queue.tail == null or queue.tail_used == queue.blocks.block_size) {
                const block = queue.blocks.acquire() catch unreachable;
                if (queue.tail) |tail| queue.blocks.link(tail, block) catch unreachable else {
                    queue.head = block;
                    queue.head_offset = 0;
                }
                queue.tail = block;
                queue.tail_used = 0;
            }
            const count = @min(remaining.len, queue.blocks.block_size - queue.tail_used);
            @memcpy(queue.tail.?.bytes[queue.tail_used..][0..count], remaining[0..count]);
            queue.tail_used += count;
            remaining = remaining[count..];
        }
        queue.byte_count += bytes.len;
    }
};

pub const Reservation = struct {
    queue: *Queue,
    byte_count: usize,
    written: usize = 0,
    original_tail: ?pools.Lease,
    original_tail_used: usize,
    tail_space: usize,
    existing_written: usize = 0,
    new_head: ?pools.Lease,
    new_tail: ?pools.Lease,
    current_new: ?pools.Lease,
    current_new_offset: usize = 0,
    final_tail_used: usize,
    finished: bool = false,

    pub fn write(reservation: *Reservation, bytes: []const u8) Error!void {
        if (reservation.finished or bytes.len > reservation.byte_count - reservation.written)
            return error.ReservationOverflow;
        var remaining = bytes;
        if (reservation.existing_written < reservation.tail_space) {
            const count = @min(
                remaining.len,
                reservation.tail_space - reservation.existing_written,
            );
            if (count > 0) {
                const start = reservation.original_tail_used + reservation.existing_written;
                @memcpy(reservation.original_tail.?.bytes[start..][0..count], remaining[0..count]);
                reservation.existing_written += count;
                reservation.written += count;
                remaining = remaining[count..];
            }
        }
        while (remaining.len > 0) {
            const block = reservation.current_new orelse return error.ReservationOverflow;
            const count = @min(
                remaining.len,
                block.bytes.len - reservation.current_new_offset,
            );
            @memcpy(block.bytes[reservation.current_new_offset..][0..count], remaining[0..count]);
            reservation.current_new_offset += count;
            reservation.written += count;
            remaining = remaining[count..];
            if (reservation.current_new_offset == block.bytes.len) {
                reservation.current_new = try reservation.queue.blocks.nextLease(block);
                reservation.current_new_offset = 0;
            }
        }
    }

    pub fn commit(
        reservation: *Reservation,
        descriptors: []const linux.fd_t,
    ) Error!void {
        if (reservation.finished or reservation.written != reservation.byte_count)
            return error.InvalidCompletion;
        try reservation.queue.descriptors.ensureCapacity(descriptors.len);

        if (reservation.new_head) |new_head| {
            if (reservation.original_tail) |tail|
                try reservation.queue.blocks.link(tail, new_head)
            else
                reservation.queue.head = new_head;
            reservation.queue.tail = reservation.new_tail;
        } else {
            reservation.queue.tail = reservation.original_tail;
        }
        reservation.queue.tail_used = reservation.final_tail_used;
        reservation.queue.byte_count += reservation.byte_count;
        for (descriptors) |fd| reservation.queue.descriptors.append(fd) catch unreachable;
        reservation.queue.reservation_active = false;
        reservation.finished = true;
        reservation.new_head = null;
    }

    pub fn abort(reservation: *Reservation) void {
        if (reservation.finished) return;
        releasePrivateChain(reservation.queue.blocks, reservation.new_head);
        reservation.queue.reservation_active = false;
        reservation.finished = true;
        reservation.new_head = null;
    }
};

fn releasePrivateChain(blocks: *pools.SharedBlocks, first: ?pools.Lease) void {
    var current = first;
    while (current) |block| {
        const next = blocks.nextLease(block) catch unreachable;
        blocks.release(block) catch unreachable;
        current = next;
    }
}

test "reservation remains private until commit and spans block boundaries" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 4, 4);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 16, &fds, 0);
    defer queue.deinit();

    try queue.enqueue("abc", &.{});
    var reservation = try queue.reserve(9);
    try reservation.write("defgh");
    try reservation.write("ijkl");
    try std.testing.expectEqual(@as(usize, 3), queue.queuedBytes());
    try std.testing.expectError(error.ReservationActive, queue.snapshot(&.{}, &.{}));
    try reservation.commit(&.{});

    var scratch: [1]linux.fd_t = undefined;
    var control: [1]u8 = undefined;
    const first = try queue.snapshot(&scratch, &control);
    try std.testing.expectEqualStrings("abcd", first.first);
    try std.testing.expectEqualStrings("efgh", first.second);
    try queue.begin(first);
    try queue.complete(8);
    const second = try queue.snapshot(&scratch, &control);
    try std.testing.expectEqualStrings("ijkl", second.first);
}

test "aborting reservation restores shared capacity and queue state" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 4, 3);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 12, &fds, 0);
    defer queue.deinit();

    try queue.enqueue("ab", &.{});
    const available = blocks.available();
    var reservation = try queue.reserve(7);
    try reservation.write("changed");
    try std.testing.expectEqual(available - 2, blocks.available());
    reservation.abort();
    try std.testing.expectEqual(available, blocks.available());
    try std.testing.expectEqual(@as(usize, 2), queue.queuedBytes());

    var scratch: [1]linux.fd_t = undefined;
    var control: [1]u8 = undefined;
    const snapshot_value = try queue.snapshot(&scratch, &control);
    try std.testing.expectEqualStrings("ab", snapshot_value.first);
}

test "reservation rejects overflow and incomplete commit" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 4, 2);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 8, &fds, 0);
    defer queue.deinit();

    var reservation = try queue.reserve(5);
    defer reservation.abort();
    try reservation.write("abcd");
    try std.testing.expectError(error.ReservationOverflow, reservation.write("ef"));
    try std.testing.expectError(error.InvalidCompletion, reservation.commit(&.{}));
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}

test "descriptor backing grows when committing a reservation" {
    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 4, 2);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var first = Queue.init(&blocks, 4, &fds, 1);
    defer first.deinit();
    var second = Queue.init(&blocks, 4, &fds, 1);
    defer second.deinit();
    try first.enqueue("x", &.{sockets[0]});

    const available = blocks.available();
    var reservation = try second.reserve(1);
    try reservation.write("y");
    try reservation.commit(&.{sockets[1]});
    try std.testing.expectEqual(@as(usize, 1), second.queuedBytes());
    try std.testing.expectEqual(@as(usize, 2), fds.capacity());
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(sockets[1], linux.F.GETFD, 0)));
    try std.testing.expectEqual(available - 1, blocks.available());
}

test "committed reservation coalesces behind active send" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 8, 2);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 16, &fds, 0);
    defer queue.deinit();
    try queue.enqueue("abc", &.{});
    var scratch: [1]linux.fd_t = undefined;
    var control: [1]u8 = undefined;
    const active = try queue.snapshot(&scratch, &control);
    try queue.begin(active);

    var reservation = try queue.reserve(3);
    try reservation.write("def");
    try reservation.commit(&.{});
    try queue.complete(3);
    const remaining = try queue.snapshot(&scratch, &control);
    try std.testing.expectEqualStrings("def", remaining.first);
}

test "shared block chain applies partial sends and coalesces appends" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 4, 3);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 12, &fds, 1);
    defer queue.deinit();

    try queue.enqueue("abcdef", &.{});
    var fd_scratch: [1]linux.fd_t = undefined;
    var control: [32]u8 = undefined;
    const first = try queue.snapshot(&fd_scratch, &control);
    try std.testing.expectEqualStrings("abcd", first.first);
    try std.testing.expectEqualStrings("ef", first.second);
    try queue.begin(first);
    try queue.complete(5);
    try queue.enqueue("ghijk", &.{});

    const coalesced = try queue.snapshot(&fd_scratch, &control);
    try std.testing.expectEqualStrings("fgh", coalesced.first);
    try std.testing.expectEqualStrings("ijk", coalesced.second);
}

test "completion cannot consume bytes appended after submission" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 8, 1);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 8, &fds, 0);
    defer queue.deinit();
    try queue.enqueue("abc", &.{});
    var control: [1]u8 = undefined;
    const submitted = try queue.snapshot(&.{}, &control);
    try queue.begin(submitted);
    try queue.enqueue("def", &.{});

    try std.testing.expectError(error.InvalidCompletion, queue.complete(4));
    try std.testing.expect(queue.sendActive());
    try queue.complete(3);
    try std.testing.expectEqual(@as(usize, 3), queue.queuedBytes());
}

test "shared pool grows while logical budget provides atomic backpressure" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 4, 1);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 8, &fds, 0);
    defer queue.deinit();

    try queue.enqueue("abcde", &.{});
    try std.testing.expectEqual(@as(usize, 2), blocks.capacity());
    try std.testing.expectError(error.ByteBudgetExceeded, queue.enqueue("efgh", &.{}));
    try std.testing.expectEqual(@as(usize, 5), queue.queuedBytes());
}

test "backpressure does not take descriptor ownership" {
    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 1, 1);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 1, &fds, 0);
    defer queue.deinit();
    try std.testing.expectError(error.DescriptorBudgetExceeded, queue.enqueue("x", &.{sockets[0]}));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(sockets[0], linux.F.GETFD, 0)));
}

test "descriptor backing grows across queues" {
    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));

    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 1, 2);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var first = Queue.init(&blocks, 1, &fds, 1);
    var second = Queue.init(&blocks, 1, &fds, 1);

    try first.enqueue("x", &.{sockets[0]});
    try second.enqueue("y", &.{sockets[1]});
    try std.testing.expectEqual(@as(usize, 1), second.queuedBytes());
    try std.testing.expectEqual(@as(usize, 2), fds.capacity());
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(sockets[1], linux.F.GETFD, 0)));

    first.deinit();
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(sockets[0], linux.F.GETFD, 0)));
    second.deinit();
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(sockets[1], linux.F.GETFD, 0)));
}

test "teardown closes descriptors and releases blocks" {
    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets));
    defer _ = linux.close(sockets[1]);

    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 1, 1);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 1, &fds, 1);
    try queue.enqueue("x", &.{sockets[0]});
    queue.deinit();
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(sockets[0], linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(usize, 1), blocks.available());
}

test "successful completion closes shared descriptors" {
    const event_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try expectSuccess(event_result);
    const event_fd: linux.fd_t = @intCast(event_result);

    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 1, 1);
    defer blocks.deinit(allocator);
    var fds = try pools.SharedFds.init(allocator, 2);
    defer fds.deinit(allocator);
    var queue = Queue.init(&blocks, 1, &fds, 1);
    defer queue.deinit();
    try queue.enqueue("x", &.{event_fd});
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control_storage: [32]u8 = undefined;
    const submitted = try queue.snapshot(&descriptor_scratch, &control_storage);
    try std.testing.expectEqual(event_fd, descriptor_scratch[0]);
    try queue.begin(submitted);
    try queue.complete(1);

    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(event_fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(usize, 2), fds.available());
    try std.testing.expectEqual(@as(usize, 0), queue.queuedDescriptors());
}

fn expectSuccess(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.UnexpectedSystemError;
}
