const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("generated_protocol");

const linux = std.os.linux;
const Core = wayring.client.Core(protocol);

test "core client operations transact IDs and generated wire messages" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer queue.deinit();
    var client_objects = try wayring.objects.ClientObjects.init(
        std.testing.allocator,
        8,
        4,
        &Core.Display.info,
        null,
    );
    defer client_objects.deinit(std.testing.allocator);
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    try std.testing.expect((try Core.Callback.info.event(0, 1)).destructor);

    const full = [_]u8{0} ** 512;
    try queue.enqueue(&full, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        Core.sync(&client_objects, &queue, null),
    );
    try std.testing.expectEqual(
        @as(?*wayring.objects.Object, null),
        client_objects.namespace.table.get(2),
    );
    try consume(&queue);

    const callback = try Core.sync(&client_objects, &queue, null);
    try std.testing.expectEqual(@as(u32, 2), callback.id);
    var message = try firstMessage(&queue);
    const sync_request = try Core.Display.decodeRequest(message, &received_fds);
    try std.testing.expectEqual(callback.id, switch (sync_request) {
        .sync => |sync_value| sync_value.callback,
        else => unreachable,
    });
    try consume(&queue);

    try Core.Callback.encodeEvent(&queue, callback.id, .{
        .done = .{ .callback_data = 77 },
    });
    message = try firstMessage(&queue);
    const done = try Core.decodeCallbackEvent(
        &client_objects,
        callback,
        message,
        &received_fds,
    );
    try std.testing.expectEqual(@as(u32, 77), switch (done) {
        .done => |value| value.callback_data,
    });
    try consume(&queue);

    try Core.Display.encodeEvent(&queue, wayring.objects.display_id, .{
        .delete_id = .{ .id = callback.id },
    });
    message = try firstMessage(&queue);
    _ = try Core.decodeDisplayEvent(&client_objects, message, &received_fds);
    try consume(&queue);

    const registry = try Core.getRegistry(&client_objects, &queue, null);
    try std.testing.expectEqual(callback.id, registry.id);
    try consume(&queue);
    const bound = try Core.bind(
        &client_objects,
        &queue,
        registry,
        9,
        &protocol.wp_wayring_test_v1.info,
        1,
        null,
    );
    message = try firstMessage(&queue);
    const bind_request = try Core.Registry.decodeRequest(message, &received_fds);
    const dynamic_id = switch (bind_request) {
        .bind => |value| value.id,
    };
    try std.testing.expectEqual(bound.id, dynamic_id.id);
    try std.testing.expectEqualStrings("wp_wayring_test_v1", dynamic_id.interface);
    try std.testing.expectEqual(@as(u32, 1), dynamic_id.version);
}

test "generic client helpers apply generated destructor lifecycle" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer queue.deinit();
    var client_objects = try wayring.objects.ClientObjects.init(
        std.testing.allocator,
        4,
        4,
        &Core.Display.info,
        null,
    );
    defer client_objects.deinit(std.testing.allocator);
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    const object = try client_objects.createLocal(&protocol.wp_wayring_test_v1.info, 1, null);
    const full = [_]u8{0} ** 64;
    try queue.enqueue(&full, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        wayring.client.sendRequest(
            protocol.wp_wayring_test_v1,
            &client_objects,
            &queue,
            object,
            .{ .destroy = .{} },
        ),
    );
    try std.testing.expect(client_objects.namespace.resolve(object) != null);
    try consume(&queue);

    try wayring.client.sendRequest(
        protocol.wp_wayring_test_v1,
        &client_objects,
        &queue,
        object,
        .{ .destroy = .{} },
    );
    try std.testing.expect(client_objects.namespace.resolve(object) == null);
    try consume(&queue);
    const next = try client_objects.createLocal(&protocol.wp_wayring_test_v1.info, 1, null);
    try std.testing.expectEqual(@as(u32, 3), next.id);
    try client_objects.deleted(object.id);
    const reused = try client_objects.createLocal(&protocol.wp_wayring_test_v1.info, 1, null);
    try std.testing.expectEqual(object.id, reused.id);

    const peer = try client_objects.insertPeer(
        wayring.objects.server_id_start,
        &protocol.wp_wayring_test_v1.info,
        1,
        null,
    );
    try wayring.client.sendRequest(
        protocol.wp_wayring_test_v1,
        &client_objects,
        &queue,
        peer,
        .{ .destroy = .{} },
    );
    try std.testing.expect(client_objects.namespace.resolve(peer) == null);
    try consume(&queue);

    const callback = try client_objects.createLocal(&Core.Callback.info, 1, null);
    try Core.Callback.encodeEvent(&queue, callback.id, .{
        .done = .{ .callback_data = 42 },
    });
    const message = try firstMessage(&queue);
    const event = try wayring.client.decodeEvent(
        Core.Callback,
        &client_objects,
        callback,
        message,
        &received_fds,
    );
    try std.testing.expectEqual(@as(u32, 42), switch (event) {
        .done => |done| done.callback_data,
    });
    try std.testing.expect(client_objects.namespace.resolve(callback) == null);
}

test "generated constructors transact typed and dynamic new IDs" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 512, &descriptors, 2);
    defer queue.deinit();
    var client_objects = try wayring.objects.ClientObjects.init(
        std.testing.allocator,
        6,
        5,
        &Core.Display.info,
        null,
    );
    defer client_objects.deinit(std.testing.allocator);
    const Interface = protocol.wp_wayring_test_v1;
    const parent = try client_objects.createLocal(&Interface.info, 1, null);
    var typed_context: u8 = 1;
    var dynamic_context: u8 = 2;

    const failed_fd_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(failed_fd_result));
    const failed_fd: linux.fd_t = @intCast(failed_fd_result);
    defer _ = linux.close(failed_fd);
    const full = [_]u8{0} ** 512;
    try queue.enqueue(&full, &.{});
    try std.testing.expectError(error.ByteBudgetExceeded, Interface.construct_all_arguments(
        &client_objects,
        &queue,
        parent,
        .{
            .signed = -1,
            .count = .first,
            .fixed_value = 256,
            .title = "rollback",
            .optional_title = null,
            .target = null,
            .child = .{ .context = &typed_context },
            .dynamic_child = .{
                .interface = &Interface.info,
                .version = 1,
                .context = &dynamic_context,
            },
            .bytes = &.{},
            .optional_bytes = null,
            .descriptor = failed_fd,
        },
    ));
    try std.testing.expectEqual(@as(usize, 2), client_objects.namespace.table.len());
    try consume(&queue);

    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_result));
    const constructed = try Interface.construct_all_arguments(
        &client_objects,
        &queue,
        parent,
        .{
            .signed = -7,
            .count = .second,
            .fixed_value = 512,
            .title = "constructed",
            .optional_title = "optional",
            .target = parent.id,
            .child = .{ .context = &typed_context },
            .dynamic_child = .{
                .interface = &Interface.info,
                .version = 1,
                .context = &dynamic_context,
            },
            .bytes = &.{ 1, 2, 3 },
            .optional_bytes = &.{4},
            .descriptor = @intCast(descriptor_result),
        },
    );
    const typed = client_objects.namespace.resolve(constructed.child).?;
    try std.testing.expectEqual(&Interface.info, typed.interface);
    try std.testing.expectEqual(@as(?*anyopaque, &typed_context), typed.context);
    const dynamic = client_objects.namespace.resolve(constructed.dynamic_child).?;
    try std.testing.expectEqual(&Interface.info, dynamic.interface);
    try std.testing.expectEqual(@as(?*anyopaque, &dynamic_context), dynamic.context);

    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 2);
    const duplicate_result = linux.fcntl(@intCast(descriptor_result), linux.F.DUPFD_CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(duplicate_result));
    try received_fds.append(@intCast(duplicate_result));
    const request = try Interface.decodeRequest(try firstMessage(&queue), &received_fds);
    const arguments = switch (request) {
        .all_arguments => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqual(constructed.child.id, arguments.child);
    try std.testing.expectEqual(constructed.dynamic_child.id, arguments.dynamic_child.id);
    try std.testing.expectEqualStrings(Interface.info.name, arguments.dynamic_child.interface);
    _ = linux.close(arguments.descriptor);
    try consume(&queue);
}

test "generated constructors accept typed IDs from external protocol modules" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer queue.deinit();
    var client_objects = try wayring.objects.ClientObjects.init(
        std.testing.allocator,
        4,
        3,
        &Core.Display.info,
        null,
    );
    defer client_objects.deinit(std.testing.allocator);
    const Interface = protocol.wp_wayring_test_v1;
    const external: wayring.metadata.Interface = .{
        .name = "wp_external_v1",
        .version = 3,
        .requests = &.{},
        .events = &.{},
    };
    const parent = try client_objects.createLocal(&Interface.info, 1, null);

    try std.testing.expectError(error.WrongInterface, Interface.construct_construct_external(
        &client_objects,
        &queue,
        parent,
        .{ .child = .{ .interface = &Interface.info } },
    ));
    try std.testing.expectEqual(@as(usize, 2), client_objects.namespace.table.len());
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());

    const constructed = try Interface.construct_construct_external(
        &client_objects,
        &queue,
        parent,
        .{ .child = .{ .interface = &external } },
    );
    const child = client_objects.namespace.resolve(constructed.child).?;
    try std.testing.expectEqual(&external, child.interface);
    try std.testing.expectEqual(@as(u32, 1), child.version);
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    const request = try Interface.decodeRequest(try firstMessage(&queue), &received_fds);
    try std.testing.expectEqual(constructed.child.id, switch (request) {
        .construct_external => |arguments| arguments.child,
        else => unreachable,
    });
    try consume(&queue);
}

test "client terminal display error stops concatenated event dispatch" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer queue.deinit();
    var fragment_storage: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(
        0,
        1,
        &fragment_storage,
        &descriptors,
        0,
        &blocks,
        64,
        0,
    );
    defer actor.deinit();
    var client_objects = try wayring.objects.ClientObjects.init(
        std.testing.allocator,
        4,
        2,
        &Core.Display.info,
        null,
    );
    defer client_objects.deinit(std.testing.allocator);
    const callback = try client_objects.createLocal(&Core.Callback.info, 1, null);

    try Core.Display.encodeEvent(&queue, wayring.objects.display_id, .{
        .@"error" = .{
            .object_id = callback.id,
            .code = 7,
            .message = "terminal",
        },
    });
    try Core.Display.encodeEvent(&queue, wayring.objects.display_id, .{
        .delete_id = .{ .id = callback.id },
    });
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    var bytes = snapshot.first;
    var handler: DisplayErrorHandler = .{ .objects = &client_objects };

    const result = Core.dispatchEvents(
        &actor,
        &client_objects.namespace,
        &bytes,
        &handler,
    );
    const failure = switch (result) {
        .terminal => |value| value,
        .dispatched => return error.ExpectedTerminalEvent,
    };
    try std.testing.expectEqual(@as(usize, 1), failure.dispatched);
    try std.testing.expectEqual(@as(?u32, wayring.objects.display_id), failure.object_id);
    try std.testing.expectEqual(error.ServerProtocolError, failure.cause);
    try std.testing.expectEqual(@as(usize, 1), handler.errors);
    try std.testing.expectEqual(@as(usize, 0), handler.deleted);
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    try std.testing.expectEqual(wayring.connection.Lifecycle.closing, actor.lifecycle);
    try std.testing.expect(client_objects.ids.isActive(callback.id));
}

const DisplayErrorHandler = struct {
    objects: *wayring.objects.ClientObjects,
    errors: usize = 0,
    deleted: usize = 0,

    pub fn event(
        handler: *DisplayErrorHandler,
        _: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const event_value = try Core.decodeDisplayEvent(handler.objects, message, fds);
        switch (event_value) {
            .@"error" => handler.errors += 1,
            .delete_id => handler.deleted += 1,
        }
        return .continue_dispatch;
    }
};

fn firstMessage(queue: *wayring.tx.Queue) !wayring.wire.Message {
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    return (try wayring.wire.Message.decode(snapshot.first)) orelse error.IncompleteMessage;
}

fn consume(queue: *wayring.tx.Queue) !void {
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    try queue.begin(snapshot);
    try queue.complete(snapshot.byteCount());
}
