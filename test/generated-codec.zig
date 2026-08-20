const std = @import("std");
const wayring = @import("wayring");
const generated = @import("generated_protocol");

const linux = std.os.linux;
const Interface = generated.wp_wayring_test_v1;
const Other = generated.wp_wayring_other_v1;
const Provider = generated.wp_enum_provider_v1;

test "generated encoder writes every argument directly into the TX queue" {
    try std.testing.expectEqualStrings("wp_wayring_test_v1", Interface.info.name);
    try std.testing.expectEqual(@as(u32, 1), (try Interface.info.request(0, 1)).since);
    try std.testing.expect((try Interface.info.request(4, 1)).destructor);
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 256, &descriptors, 1);

    try std.testing.expectError(
        error.InvalidString,
        Interface.encodeRequest(&queue, 7, .{ .set_title = .{ .title = "bad\x00string" } }),
    );
    try std.testing.expectError(
        error.InvalidString,
        Interface.requestSize(.{ .set_title = .{ .title = "bad\x00string" } }),
    );
    try std.testing.expectError(
        error.NullObject,
        Interface.encodeRequest(&queue, 7, .{ .set_target = .{ .target = 0 } }),
    );
    try std.testing.expectError(
        error.NullObject,
        Interface.requestSize(.{ .set_target = .{ .target = 0 } }),
    );
    const oversized = try std.testing.allocator.alloc(u8, wayring.wire.max_message_len);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.MessageTooLarge,
        Interface.encodeRequest(&queue, 7, .{ .set_title = .{ .title = oversized } }),
    );
    try std.testing.expectError(
        error.MessageTooLarge,
        Interface.requestSize(.{ .set_title = .{ .title = oversized } }),
    );
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
    try std.testing.expectEqual(@as(usize, 2), blocks.available());
    try std.testing.expectEqual(
        wayring.wire.header_len,
        try Interface.requestSize(.{ .destroy = .{} }),
    );

    const original_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try expectSuccess(original_result);
    const original: linux.fd_t = @intCast(original_result);
    const received_result = linux.fcntl(original, linux.F.DUPFD_CLOEXEC, 0);
    try expectSuccess(received_result);
    const received: linux.fd_t = @intCast(received_result);

    const request: Interface.Request = .{ .all_arguments = .{
        .signed = -17,
        .count = Interface.mode.fromInt(42),
        .fixed_value = -256,
        .title = "wayring",
        .optional_title = null,
        .target = null,
        .child = 9,
        .dynamic_child = .{
            .interface = "wp_dynamic_v1",
            .version = 3,
            .id = 11,
        },
        .bytes = &.{ 1, 2, 3, 4, 5 },
        .optional_bytes = null,
        .descriptor = original,
    } };
    const encoded_size = try Interface.requestSize(request);
    try Interface.encodeRequest(&queue, 7, request);

    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    try std.testing.expectEqual(original, descriptor_scratch[0]);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    try std.testing.expectEqual(@as(u32, 7), message.header.object_id);
    try std.testing.expectEqual(encoded_size, message.header.size);

    var received_queue = wayring.ancillary.FdQueue.init(&descriptors, 1);
    try received_queue.append(received);
    const decoded = try Interface.decodeRequest(message, &received_queue);
    const payload = switch (decoded) {
        .all_arguments => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(i32, -17), payload.signed);
    try std.testing.expectEqual(@as(u32, 42), payload.count.toInt());
    try std.testing.expect(payload.count.contains(Interface.mode.second));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Interface.mode));
    try std.testing.expectEqual(@as(i32, -256), payload.fixed_value);
    try std.testing.expectEqualStrings("wayring", payload.title);
    try std.testing.expectEqual(null, payload.optional_title);
    try std.testing.expectEqual(null, payload.target);
    try std.testing.expectEqual(@as(u32, 9), payload.child);
    try std.testing.expectEqualStrings("wp_dynamic_v1", payload.dynamic_child.interface);
    try std.testing.expectEqual(@as(u32, 3), payload.dynamic_child.version);
    try std.testing.expectEqual(@as(u32, 11), payload.dynamic_child.id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, payload.bytes);
    try std.testing.expectEqual(null, payload.optional_bytes);
    try std.testing.expectEqual(received, payload.descriptor);
    _ = linux.close(payload.descriptor);

    queue.deinit();
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(original, linux.F.GETFD, 0)));
}

test "validated decoding checks object references before taking descriptors" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 128, &descriptors, 1);
    defer queue.deinit();
    var namespace = try wayring.objects.Namespace.init(std.testing.allocator, 2);
    defer namespace.deinit(std.testing.allocator);

    const original_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try expectSuccess(original_result);
    const original: linux.fd_t = @intCast(original_result);
    const received_result = linux.fcntl(original, linux.F.DUPFD_CLOEXEC, 0);
    try expectSuccess(received_result);
    const received: linux.fd_t = @intCast(received_result);
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 1);
    try received_fds.append(received);

    try Interface.encodeRequest(&queue, 7, .{ .all_arguments = .{
        .signed = 0,
        .count = .first,
        .fixed_value = 0,
        .title = "object validation",
        .optional_title = null,
        .target = 9,
        .child = 10,
        .dynamic_child = .{ .interface = Interface.info.name, .version = 1, .id = 11 },
        .bytes = &.{},
        .optional_bytes = null,
        .descriptor = original,
    } });
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;

    try std.testing.expectError(
        error.UnknownObject,
        Interface.decodeRequestObjects(&namespace, message, &received_fds),
    );
    try std.testing.expectEqual(@as(usize, 1), received_fds.len());

    const wrong = try namespace.insert(9, &Other.info, 1, null);
    try std.testing.expectError(
        error.WrongInterface,
        Interface.decodeRequestObjects(&namespace, message, &received_fds),
    );
    try std.testing.expectEqual(@as(usize, 1), received_fds.len());
    _ = namespace.remove(wrong);
    _ = try namespace.insert(9, &Interface.info, 1, null);

    const decoded = try Interface.decodeRequestObjects(&namespace, message, &received_fds);
    const payload = switch (decoded) {
        .all_arguments => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(?u32, 9), payload.target);
    try std.testing.expectEqual(@as(usize, 0), received_fds.len());
    _ = linux.close(payload.descriptor);
}

test "generated enum wrappers preserve unknown signed values" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer queue.deinit();
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    try Interface.encodeRequest(&queue, 7, .{
        .set_direction = .{ .direction = Other.direction.fromInt(-17) },
    });
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const decoded = try Interface.decodeRequest(message, &received_fds);
    try std.testing.expectEqual(@as(i32, -17), switch (decoded) {
        .set_direction => |value| value.direction.toInt(),
        else => unreachable,
    });
    try std.testing.expectEqual(@as(i32, -1), Other.direction.backward.toInt());
}

test "composed protocols share external enum types" {
    try std.testing.expectEqual(@as(u32, 1), Provider.info.version);
    try std.testing.expectEqual(@as(u32, 1), Provider.version.current.toInt());
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer queue.deinit();
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    try Interface.encodeRequest(&queue, 7, .{
        .set_external_state = .{ .state = Provider.state.active },
    });
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const decoded = try Interface.decodeRequest(message, &received_fds);
    try std.testing.expectEqual(Provider.state.active, switch (decoded) {
        .set_external_state => |value| value.state,
        else => unreachable,
    });
}

fn expectSuccess(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.UnexpectedSystemError;
}
