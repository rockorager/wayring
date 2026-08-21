const std = @import("std");
const wayring = @import("wayring");
const generated = @import("generated_protocol");

const linux = std.os.linux;
const native_endian = @import("builtin").cpu.arch.endian();

test "fuzz wire decoding" {
    try std.testing.fuzz({}, fuzzWire, .{});
}

fn fuzzWire(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const len = smith.slice(&storage);
    const bytes = storage[0..len];

    const header = wayring.wire.Header.decode(bytes) catch return;
    if (header) |value| {
        try std.testing.expect(bytes.len >= wayring.wire.header_len);
        try std.testing.expect(value.object_id != 0);
        try std.testing.expect(value.size >= wayring.wire.header_len);
        try std.testing.expectEqual(@as(u16, 0), value.size % 4);

        var encoded: [wayring.wire.header_len]u8 = undefined;
        try value.encode(&encoded);
        const decoded = (try wayring.wire.Header.decode(&encoded)).?;
        try std.testing.expectEqualDeep(value, decoded);

        const message = try wayring.wire.Message.decode(bytes);
        if (message) |complete| {
            try std.testing.expect(bytes.len >= complete.header.size);
            try std.testing.expectEqual(
                @as(usize, complete.header.size - wayring.wire.header_len),
                complete.payload.len,
            );
        } else {
            try std.testing.expect(bytes.len < value.size);
        }
    } else {
        try std.testing.expect(bytes.len < wayring.wire.header_len);
    }

    var arguments = (wayring.wire.Message{
        .header = .{ .object_id = 1, .opcode = 0, .size = @intCast(wayring.wire.header_len + len & ~@as(usize, 3)) },
        .payload = bytes,
    }).arguments();
    for (0..16) |_| {
        const before = arguments.remaining();
        const operation = smith.valueRangeAtMost(u8, 0, 3);
        switch (operation) {
            0 => _ = arguments.uint() catch break,
            1 => _ = arguments.int() catch break,
            2 => _ = arguments.string() catch break,
            3 => _ = arguments.array() catch break,
            else => unreachable,
        }
        try std.testing.expect(arguments.remaining() <= before);
    }
}

test "fuzz stream fragmentation against contiguous framing" {
    try std.testing.fuzz({}, fuzzStream, .{});
}

fn fuzzStream(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    var starts: [8]usize = undefined;
    var sizes: [8]usize = undefined;
    const frame_count = smith.valueRangeAtMost(u8, 1, starts.len);
    var used: usize = 0;
    for (0..frame_count) |index| {
        const payload_words = smith.valueRangeAtMost(u8, 0, 8);
        const size = wayring.wire.header_len + @as(usize, payload_words) * 4;
        starts[index] = used;
        sizes[index] = size;
        try (wayring.wire.Header{
            .object_id = smith.valueRangeAtMost(u32, 1, std.math.maxInt(u32)),
            .opcode = smith.value(u16),
            .size = @intCast(size),
        }).encode(storage[used..][0..wayring.wire.header_len]);
        smith.bytes(storage[used + wayring.wire.header_len ..][0 .. size - wayring.wire.header_len]);
        used += size;
    }

    var scratch: [512]u8 = undefined;
    var framer = wayring.stream.Framer.init(&scratch);
    var emitted: usize = 0;
    var offset: usize = 0;
    while (offset < used) {
        const chunk_len: usize = smith.valueRangeAtMost(
            u16,
            1,
            @intCast(used - offset),
        );
        var chunk: []const u8 = storage[offset..][0..chunk_len];
        offset += chunk_len;
        while (chunk.len != 0) {
            const before = chunk.len;
            const message = try framer.next(&chunk);
            try std.testing.expect(chunk.len < before or message != null);
            if (message) |value| {
                try expectFrame(value, storage[starts[emitted]..][0..sizes[emitted]]);
                emitted += 1;
            }
        }
    }
    var empty: []const u8 = &.{};
    while (try framer.next(&empty)) |message| {
        try expectFrame(message, storage[starts[emitted]..][0..sizes[emitted]]);
        emitted += 1;
    }
    try std.testing.expectEqual(@as(usize, frame_count), emitted);
    try std.testing.expectEqual(@as(usize, 0), framer.pending());
}

fn expectFrame(actual: wayring.wire.Message, encoded: []const u8) !void {
    const expected = (try wayring.wire.Message.decode(encoded)).?;
    try std.testing.expectEqualDeep(expected.header, actual.header);
    try std.testing.expectEqualSlices(u8, expected.payload, actual.payload);
}

test "fuzz descriptor budgets and ownership" {
    try std.testing.fuzz({}, fuzzDescriptors, .{});
}

fn fuzzDescriptors(_: void, smith: *std.testing.Smith) !void {
    const count = smith.valueRangeAtMost(u8, 1, 4);
    const budget = smith.valueRangeAtMost(u8, 0, 4);
    var fds: [4]linux.fd_t = undefined;
    for (fds[0..count]) |*fd| fd.* = try createDescriptor();

    var control_storage: [128]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const control = try wayring.ancillary.encodeRights(&control_storage, fds[0..count]);
    var pool = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);
    var queue = wayring.ancillary.FdQueue.init(&pool, budget);

    if (budget < count) {
        try std.testing.expectError(
            error.DescriptorBudgetExceeded,
            wayring.ancillary.enqueueRights(control, &queue),
        );
        try std.testing.expectEqual(@as(usize, 0), queue.len());
    } else {
        try std.testing.expectEqual(
            @as(usize, count),
            try wayring.ancillary.enqueueRights(control, &queue),
        );
        try std.testing.expectEqual(@as(usize, count), queue.len());
        for (fds[0..count]) |expected| {
            const actual = try queue.pop();
            try std.testing.expectEqual(expected, actual);
            _ = linux.close(actual);
        }
    }
    queue.deinit();
    for (fds[0..count]) |fd| {
        try std.testing.expectEqual(
            linux.E.BADF,
            linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)),
        );
    }
}

test "fuzz generated decoder descriptor transaction" {
    try std.testing.fuzz({}, fuzzGeneratedDescriptorDecode, .{});
}

fn fuzzGeneratedDescriptorDecode(_: void, smith: *std.testing.Smith) !void {
    const Interface = generated.wp_wayring_test_v1;
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 256, &descriptors, 1);
    defer queue.deinit();

    const original = try createDescriptor();
    try Interface.encodeRequest(&queue, 7, .{ .all_arguments = .{
        .signed = -17,
        .count = .first,
        .fixed_value = 256,
        .title = "fuzz",
        .optional_title = null,
        .target = null,
        .child = 9,
        .dynamic_child = .{ .interface = "dynamic_v1", .version = 1, .id = 10 },
        .bytes = &.{ 1, 2, 3, 4 },
        .optional_bytes = null,
        .descriptor = original,
    } });
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    var encoded: [256]u8 = undefined;
    @memcpy(encoded[0..snapshot.first.len], snapshot.first);

    const mutation_count = smith.valueRangeAtMost(u8, 0, 4);
    for (0..mutation_count) |_| {
        const index = smith.valueRangeAtMost(
            u16,
            wayring.wire.header_len,
            @intCast(snapshot.first.len - 1),
        );
        encoded[index] = smith.value(u8);
    }
    var header = (try wayring.wire.Header.decode(&encoded)).?;
    header.opcode = smith.valueRangeAtMost(
        u16,
        0,
        @intCast(Interface.info.requests.len + 1),
    );
    try header.encode(encoded[0..wayring.wire.header_len]);
    const message = (try wayring.wire.Message.decode(encoded[0..snapshot.first.len])).?;

    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 1);
    defer received_fds.deinit();
    var received: ?linux.fd_t = null;
    if (smith.boolWeighted(1, 1)) {
        const duplicate = linux.fcntl(original, linux.F.DUPFD_CLOEXEC, 0);
        try expectSuccess(duplicate);
        received = @intCast(duplicate);
        try received_fds.append(received.?);
    }
    const before = received_fds.len();
    if (Interface.decodeRequest(message, &received_fds)) |_| {
        try std.testing.expect(received_fds.len() <= before);
    } else |_| {
        try std.testing.expectEqual(before, received_fds.len());
    }
    if (received != null and received_fds.len() == 0) {
        _ = linux.close(received.?);
    }
}

test "fuzz dispatch stop and lookup behavior" {
    try std.testing.fuzz({}, fuzzDispatch, .{});
}

fn fuzzDispatch(_: void, smith: *std.testing.Smith) !void {
    const info: wayring.metadata.Interface = .{
        .name = "fuzz_v1",
        .version = 2,
        .requests = &.{ .{ .since = 1 }, .{ .since = 2 } },
        .events = &.{},
    };
    var namespace = try wayring.objects.Namespace.init(std.testing.allocator, 1);
    defer namespace.deinit(std.testing.allocator);
    _ = try namespace.insert(4, &info, 1, null);
    var fd_pool = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer fd_pool.deinit(std.testing.allocator);
    var tx_blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 1);
    defer tx_blocks.deinit(std.testing.allocator);
    var fragment_storage: [128]u8 = undefined;
    var actor = wayring.connection.Actor.init(
        0,
        1,
        &fragment_storage,
        &fd_pool,
        0,
        &tx_blocks,
        128,
        0,
    );
    defer actor.deinit();

    const frame_count = smith.valueRangeAtMost(u8, 1, 8);
    const behavior = smith.valueRangeAtMost(u8, 0, 3);
    const invalid_lookup = behavior != 0;
    const decisive_index = smith.valueRangeAtMost(u8, 0, frame_count - 1);
    var storage: [8 * 12]u8 = undefined;
    var expected_total: u32 = 0;
    for (0..frame_count) |index| {
        const value = smith.value(u32);
        if (index <= decisive_index and (!invalid_lookup or index < decisive_index))
            expected_total +%= value;
        try encodeDispatchFrame(
            storage[index * 12 ..][0..12],
            if (behavior == 1 and index == decisive_index) 5 else 4,
            if (behavior >= 2 and index == decisive_index)
                if (behavior == 2) 2 else 1
            else
                0,
            value,
        );
    }
    var bytes: []const u8 = storage[0 .. @as(usize, frame_count) * 12];
    var handler: DispatchHandler = .{
        .actor = &actor,
        .stop_after = if (invalid_lookup) frame_count + 1 else decisive_index + 1,
    };
    if (invalid_lookup) {
        const result = wayring.dispatch.requests(&actor, &namespace, &bytes, &handler);
        switch (behavior) {
            1 => try std.testing.expectError(error.UnknownObject, result),
            2 => try std.testing.expectError(error.UnknownOpcode, result),
            3 => try std.testing.expectError(error.UnsupportedVersion, result),
            else => unreachable,
        }
        try std.testing.expectEqual(@as(usize, decisive_index), handler.count);
        try std.testing.expectEqual(
            @as(usize, frame_count - decisive_index - 1) * 12,
            bytes.len,
        );
        try std.testing.expectEqual(expected_total, handler.total);
        return;
    }
    const dispatched = decisive_index + 1;
    try std.testing.expectEqual(
        @as(usize, dispatched),
        try wayring.dispatch.requests(&actor, &namespace, &bytes, &handler),
    );
    try std.testing.expectEqual(expected_total, handler.total);
    try std.testing.expectEqual(
        @as(usize, frame_count - dispatched) * 12,
        bytes.len,
    );
    const remaining = bytes.len;
    try std.testing.expectEqual(
        @as(usize, 0),
        try wayring.dispatch.requests(&actor, &namespace, &bytes, &handler),
    );
    try std.testing.expectEqual(remaining, bytes.len);
}

const DispatchHandler = struct {
    actor: *wayring.connection.Actor,
    stop_after: usize,
    count: usize = 0,
    total: u32 = 0,

    pub fn request(
        handler: *DispatchHandler,
        _: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        _: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        var arguments = message.arguments();
        handler.total +%= try arguments.uint();
        try arguments.finish();
        handler.count += 1;
        if (handler.count == handler.stop_after) {
            try handler.actor.beginProtocolError();
            return .stop;
        }
        return .continue_dispatch;
    }
};

fn encodeDispatchFrame(storage: []u8, object_id: u32, opcode: u16, value: u32) !void {
    try (wayring.wire.Header{
        .object_id = object_id,
        .opcode = opcode,
        .size = 12,
    }).encode(storage[0..wayring.wire.header_len]);
    std.mem.writeInt(u32, storage[wayring.wire.header_len..12], value, native_endian);
}

fn createDescriptor() !linux.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try expectSuccess(result);
    return @intCast(result);
}

fn expectSuccess(result: usize) !void {
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
}
