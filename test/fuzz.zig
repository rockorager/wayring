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

test "fuzz reactor slot generations against a free-list model" {
    try std.testing.fuzz({}, fuzzReactorSlots, .{});
}

fn fuzzReactorSlots(_: void, smith: *std.testing.Smith) !void {
    var storage: [8]wayring.reactor.Slot = undefined;
    const capacity = smith.valueRangeAtMost(u8, 1, storage.len);
    var slots = wayring.reactor.Slots.init(storage[0..capacity]);
    var active = [_]bool{false} ** storage.len;
    var generations = [_]u32{0} ** storage.len;
    var free: [8]u8 = undefined;
    for (0..capacity) |index| free[index] = capacity - 1 - @as(u8, @intCast(index));
    var free_len: usize = capacity;

    var steps: usize = 0;
    while (steps < 128 and !smith.eosWeightedSimple(16, 1)) : (steps += 1) {
        const index = smith.valueRangeAtMost(u8, 0, capacity - 1);
        switch (smith.valueRangeAtMost(u8, 0, 3)) {
            0 => {
                if (free_len == 0) {
                    try std.testing.expectError(error.Exhausted, slots.acquire());
                } else {
                    const expected_index = free[free_len - 1];
                    free_len -= 1;
                    generations[expected_index] = wayring.completion.nextGeneration(
                        generations[expected_index],
                    );
                    active[expected_index] = true;
                    const acquired = try slots.acquire();
                    try std.testing.expectEqual(@as(u24, expected_index), acquired.index);
                    try std.testing.expectEqual(generations[expected_index], acquired.generation);
                }
            },
            1 => if (active[index]) {
                try slots.deactivate(index, generations[index]);
                active[index] = false;
                free[free_len] = index;
                free_len += 1;
            } else {
                try std.testing.expectError(
                    error.SlotInactive,
                    slots.deactivate(index, generations[index]),
                );
            },
            2 => if (active[index]) {
                const wrong = wayring.completion.nextGeneration(generations[index]);
                try std.testing.expectError(
                    error.WrongGeneration,
                    slots.deactivate(index, wrong),
                );
            } else {
                try std.testing.expectError(
                    error.SlotInactive,
                    slots.deactivate(index, generations[index]),
                );
            },
            3 => {
                const use_current = smith.boolWeighted(1, 1);
                const generation = if (use_current)
                    generations[index]
                else
                    generations[index] -% 1;
                const token = (wayring.completion.Token{
                    .slot = index,
                    .generation = generation,
                    .operation = .receive,
                }).encode();
                const routed = slots.route(token);
                if (active[index] and generation == generations[index]) {
                    try std.testing.expectEqual(index, routed.?.slot);
                    try std.testing.expectEqual(
                        wayring.completion.Operation.receive,
                        routed.?.operation,
                    );
                } else try std.testing.expectEqual(null, routed);
            },
            else => unreachable,
        }
        try std.testing.expectEqual(capacity - free_len, slots.active_count);
        for (active[0..capacity], 0..) |is_active, model_index| {
            const current = (wayring.completion.Token{
                .slot = @intCast(model_index),
                .generation = generations[model_index],
                .operation = .send,
            }).encode();
            try std.testing.expectEqual(is_active, slots.route(current) != null);
        }
    }

    for (active[0..capacity], 0..) |is_active, index| {
        if (is_active) try slots.deactivate(@intCast(index), generations[index]);
    }
    try std.testing.expectEqual(@as(usize, 0), slots.active_count);
}

test "fuzz connection completion state against a lifecycle model" {
    try std.testing.fuzz({}, fuzzConnectionState, .{});
}

fn fuzzConnectionState(_: void, smith: *std.testing.Smith) !void {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 16, 8);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
    defer descriptors.deinit(std.testing.allocator);
    var fragment_storage: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(
        2,
        7,
        &fragment_storage,
        &descriptors,
        0,
        &blocks,
        64,
        0,
    );

    var lifecycle: wayring.connection.Lifecycle = .open;
    var receive_active = false;
    var cancel_requested = false;
    var cancel_active = false;
    var queued_bytes: usize = 0;
    var send_active = false;
    var send_bytes: usize = 0;

    var steps: usize = 0;
    while (steps < 128 and !smith.eosWeightedSimple(16, 1)) : (steps += 1) {
        switch (smith.valueRangeAtMost(u8, 0, 10)) {
            0 => {
                var bytes: [16]u8 = undefined;
                const len = smith.valueRangeAtMost(u8, 1, bytes.len);
                smith.bytes(bytes[0..len]);
                if (lifecycle != .open) {
                    try std.testing.expectError(error.Closing, actor.enqueue(bytes[0..len], &.{}));
                } else if (queued_bytes + len > 64) {
                    try std.testing.expectError(
                        error.ByteBudgetExceeded,
                        actor.enqueue(bytes[0..len], &.{}),
                    );
                } else {
                    try actor.enqueue(bytes[0..len], &.{});
                    queued_bytes += len;
                }
            },
            1 => if (lifecycle != .open) {
                try std.testing.expectError(error.Closing, actor.armReceive());
            } else if (receive_active) {
                try std.testing.expectError(error.ReceiveAlreadyActive, actor.armReceive());
            } else {
                _ = try actor.armReceive();
                receive_active = true;
            },
            2 => {
                const kind = smith.valueRangeAtMost(u8, 0, 4);
                const more = smith.boolWeighted(1, 1);
                const result: i32 = switch (kind) {
                    0 => smith.valueRangeAtMost(i32, 1, 64),
                    1 => 0,
                    2 => -@as(i32, @intFromEnum(linux.E.CANCELED)),
                    3 => -@as(i32, @intFromEnum(linux.E.NOBUFS)),
                    4 => -@as(i32, @intFromEnum(linux.E.IO)),
                    else => unreachable,
                };
                const completion = cqe(.receive, result, if (more) linux.IORING_CQE_F_MORE else 0);
                if (!receive_active) {
                    try std.testing.expectError(
                        error.ReceiveNotActive,
                        actor.completeRouted(.receive, completion),
                    );
                } else switch (kind) {
                    0 => {
                        const event = try actor.completeRouted(.receive, completion);
                        try std.testing.expectEqual(@as(usize, @intCast(result)), event.received.length);
                        try std.testing.expectEqual(more, event.received.more);
                        receive_active = more;
                    },
                    1 => {
                        try std.testing.expectEqual(
                            wayring.connection.Event.disconnected,
                            try actor.completeRouted(.receive, completion),
                        );
                        receive_active = false;
                        lifecycle = .closing;
                    },
                    2 => {
                        receive_active = false;
                        if (lifecycle == .open) {
                            try std.testing.expectError(
                                error.IoFailure,
                                actor.completeRouted(.receive, completion),
                            );
                            lifecycle = .closing;
                        } else try std.testing.expectEqual(
                            wayring.connection.Event.receive_stopped,
                            try actor.completeRouted(.receive, completion),
                        );
                    },
                    3 => {
                        try std.testing.expectEqual(
                            wayring.connection.Event.buffers_exhausted,
                            try actor.completeRouted(.receive, completion),
                        );
                        receive_active = false;
                    },
                    4 => {
                        try std.testing.expectError(
                            error.IoFailure,
                            actor.completeRouted(.receive, completion),
                        );
                        receive_active = false;
                        lifecycle = .closing;
                    },
                    else => unreachable,
                }
            },
            3 => if (queued_bytes != 0) {
                var descriptor_scratch: [1]linux.fd_t = undefined;
                var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
                const snapshot = try actor.transmit.snapshot(&descriptor_scratch, &control);
                if (lifecycle == .protocol_error) {
                    try std.testing.expectError(error.ProtocolErrorPending, actor.beginSend(snapshot));
                } else if (lifecycle == .closing) {
                    try std.testing.expectError(error.Closing, actor.beginSend(snapshot));
                } else if (send_active) {
                    try std.testing.expectError(error.SendAlreadyActive, actor.beginSend(snapshot));
                } else {
                    _ = try actor.beginSend(snapshot);
                    send_active = true;
                    send_bytes = snapshot.byteCount();
                }
            },
            4 => {
                const fail = smith.boolWeighted(3, 1);
                if (!send_active) {
                    try std.testing.expectError(
                        error.NoSendActive,
                        actor.completeRouted(.send, cqe(.send, if (fail) -1 else 1, 0)),
                    );
                } else if (fail) {
                    if (lifecycle == .closing) {
                        try std.testing.expectEqual(
                            wayring.connection.Event.send_stopped,
                            try actor.completeRouted(
                                .send,
                                cqe(.send, -@as(i32, @intFromEnum(linux.E.CANCELED)), 0),
                            ),
                        );
                    } else {
                        try std.testing.expectError(
                            error.IoFailure,
                            actor.completeRouted(.send, cqe(.send, -1, 0)),
                        );
                        lifecycle = .closing;
                    }
                    send_active = false;
                    send_bytes = 0;
                } else {
                    const written = smith.valueRangeAtMost(u16, 1, @intCast(send_bytes));
                    const event = try actor.completeRouted(
                        .send,
                        cqe(.send, @intCast(written), 0),
                    );
                    queued_bytes -= written;
                    send_active = false;
                    send_bytes = 0;
                    try std.testing.expectEqual(queued_bytes != 0, event.sent.more_queued);
                    if (lifecycle == .draining and queued_bytes == 0) lifecycle = .closing;
                }
            },
            5 => if (lifecycle == .open) {
                try actor.beginProtocolError();
                lifecycle = .protocol_error;
            } else try std.testing.expectError(error.Closing, actor.beginProtocolError()),
            6 => if (lifecycle != .protocol_error) {
                try std.testing.expectError(error.NoProtocolError, actor.commitProtocolError());
            } else if (queued_bytes == 0) {
                try std.testing.expectError(error.EmptyMessage, actor.commitProtocolError());
            } else {
                try actor.commitProtocolError();
                lifecycle = .draining;
            },
            7 => {
                actor.beginClose();
                lifecycle = .closing;
            },
            8 => {
                actor.beginClose();
                lifecycle = .closing;
                if ((receive_active or send_active) and !cancel_requested) {
                    actor.cancel_requested = true;
                    actor.cancel_active = true;
                    cancel_requested = true;
                    cancel_active = true;
                }
            },
            9 => {
                const kind = smith.valueRangeAtMost(u8, 0, 3);
                const result: i32 = switch (kind) {
                    0 => 0,
                    1 => -@as(i32, @intFromEnum(linux.E.NOENT)),
                    2 => -@as(i32, @intFromEnum(linux.E.ALREADY)),
                    3 => -@as(i32, @intFromEnum(linux.E.IO)),
                    else => unreachable,
                };
                if (!cancel_active) {
                    try std.testing.expectError(
                        error.CancelNotActive,
                        actor.completeRouted(.cancel, cqe(.cancel, result, 0)),
                    );
                } else if (kind == 3) {
                    try std.testing.expectError(
                        error.IoFailure,
                        actor.completeRouted(.cancel, cqe(.cancel, result, 0)),
                    );
                    cancel_active = false;
                    lifecycle = .closing;
                } else {
                    try std.testing.expectEqual(
                        wayring.connection.Event.cancel_complete,
                        try actor.completeRouted(.cancel, cqe(.cancel, result, 0)),
                    );
                    cancel_active = false;
                }
            },
            10 => {
                const stale = (wayring.completion.Token{
                    .slot = actor.slot,
                    .generation = actor.generation -% 1,
                    .operation = .receive,
                }).encode();
                try std.testing.expectError(error.StaleCompletion, actor.complete(.{
                    .user_data = stale,
                    .res = 1,
                    .flags = linux.IORING_CQE_F_MORE,
                }));
            },
            else => unreachable,
        }
        try std.testing.expectEqual(lifecycle, actor.lifecycle);
        try std.testing.expectEqual(receive_active, actor.receive_active);
        try std.testing.expectEqual(cancel_requested, actor.cancel_requested);
        try std.testing.expectEqual(cancel_active, actor.cancel_active);
        try std.testing.expectEqual(queued_bytes, actor.transmit.queuedBytes());
        try std.testing.expectEqual(send_active, actor.transmit.sendActive());
    }

    actor.beginClose();
    if (actor.receive_active) {
        _ = try actor.completeRouted(
            .receive,
            cqe(.receive, -@as(i32, @intFromEnum(linux.E.CANCELED)), 0),
        );
    }
    if (actor.cancel_active) {
        _ = try actor.completeRouted(.cancel, cqe(.cancel, 0, 0));
    }
    if (actor.transmit.sendActive()) {
        _ = try actor.completeRouted(
            .send,
            cqe(.send, -@as(i32, @intFromEnum(linux.E.CANCELED)), 0),
        );
    }
    try std.testing.expect(actor.canDeinit());
    actor.deinit();
    try std.testing.expectEqual(@as(usize, 8), blocks.available());
    try std.testing.expectEqual(@as(usize, 2), descriptors.available());
}

fn cqe(
    operation: wayring.completion.Operation,
    result: i32,
    flags: u32,
) linux.io_uring_cqe {
    return .{
        .user_data = (wayring.completion.Token{
            .slot = 2,
            .generation = 7,
            .operation = operation,
        }).encode(),
        .res = result,
        .flags = flags,
    };
}
