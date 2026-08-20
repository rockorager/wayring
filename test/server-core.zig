const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("generated_protocol");

const linux = std.os.linux;
const Core = wayring.server.Core(protocol);

test "core server creates resources and coalesces callback completion" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer queue.deinit();
    var object_pool = try wayring.objects.SharedObjectPool.init(std.testing.allocator, 8);
    defer object_pool.deinit(std.testing.allocator);
    var object_buckets = [_]wayring.objects.SharedObjectBucket{.{}} ** 8;
    var server_objects = try wayring.objects.SharedServerObjects.init(
        &object_pool,
        &object_buckets,
        1,
        8,
        &Core.Display.info,
        null,
    );
    defer server_objects.deinit();
    var globals = try wayring.server.Globals.init(std.testing.allocator, 4);
    defer globals.deinit(std.testing.allocator);
    const test_global = try globals.add(
        &protocol.wp_wayring_test_v1.info,
        1,
        null,
    );
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    try Core.Display.encodeRequest(&queue, wayring.objects.display_id, .{
        .sync = .{ .callback = 2 },
    });
    var message = try firstMessage(&queue);
    const action = try Core.decodeDisplayRequest(
        &server_objects,
        message,
        &received_fds,
        null,
    );
    const callback = switch (action) {
        .sync => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(u32, 2), callback.id);
    try consume(&queue);

    const almost_full = [_]u8{0} ** 500;
    try queue.enqueue(&almost_full, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        Core.completeSync(&server_objects, &queue, callback, 91),
    );
    try std.testing.expect(server_objects.namespace.resolve(callback) != null);
    try consume(&queue);

    try Core.completeSync(&server_objects, &queue, callback, 91);
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const done = try Core.Callback.decodeEvent(message, &received_fds);
    try std.testing.expectEqual(@as(u32, 91), switch (done) {
        .done => |value| value.callback_data,
    });
    const second_bytes = snapshot.first[message.header.size..];
    const second = (try wayring.wire.Message.decode(second_bytes)).?;
    const deleted = try Core.Display.decodeEvent(second, &received_fds);
    try std.testing.expectEqual(callback.id, switch (deleted) {
        .delete_id => |value| value.id,
        else => unreachable,
    });
    try std.testing.expect(server_objects.namespace.resolve(callback) == null);
    try consume(&queue);

    try Core.Display.encodeRequest(&queue, wayring.objects.display_id, .{
        .get_registry = .{ .registry = 3 },
    });
    message = try firstMessage(&queue);
    const registry_action = try Core.decodeDisplayRequest(
        &server_objects,
        message,
        &received_fds,
        null,
    );
    const registry = switch (registry_action) {
        .get_registry => |value| value,
        else => unreachable,
    };
    try consume(&queue);

    var global_cursor = globals.cursor();
    try queue.enqueue(&almost_full, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        Core.advertiseNext(
            &server_objects,
            &queue,
            registry,
            &global_cursor,
        ),
    );
    try std.testing.expectEqual(test_global, global_cursor.pending.?.handle);
    try consume(&queue);
    try std.testing.expect(try Core.advertiseNext(
        &server_objects,
        &queue,
        registry,
        &global_cursor,
    ));
    message = try firstMessage(&queue);
    const global = try Core.Registry.decodeEvent(message, &received_fds);
    try std.testing.expectEqualStrings("wp_wayring_test_v1", switch (global) {
        .global => |value| value.interface,
        else => unreachable,
    });
    try consume(&queue);

    try Core.Registry.encodeRequest(&queue, registry.id, .{ .bind = .{
        .name = test_global.id,
        .id = .{
            .interface = "wp_wayring_test_v1",
            .version = 1,
            .id = 4,
        },
    } });
    message = try firstMessage(&queue);
    const bind_request = try Core.decodeRegistryRequest(
        &server_objects,
        registry,
        message,
        &received_fds,
    );
    const bound = try Core.bindGlobal(&server_objects, &globals, bind_request);
    try std.testing.expectEqual(@as(u32, 4), bound.id);
}

test "generic server requests finish generated destructor lifecycle" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var receive_queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer receive_queue.deinit();
    var transmit_queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer transmit_queue.deinit();
    var object_pool = try wayring.objects.SharedObjectPool.init(std.testing.allocator, 6);
    defer object_pool.deinit(std.testing.allocator);
    var buckets = [_]wayring.objects.SharedObjectBucket{.{}} ** 8;
    var server_objects = try wayring.objects.SharedServerObjects.init(
        &object_pool,
        &buckets,
        1,
        6,
        &Core.Display.info,
        null,
    );
    defer server_objects.deinit();
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    const Interface = protocol.wp_wayring_test_v1;

    const client_object = try server_objects.insertClient(2, &Interface.info, 1, null);
    try Interface.encodeRequest(&receive_queue, client_object.id, .{ .destroy = .{} });
    var message = try firstMessage(&receive_queue);
    const client_request = try wayring.server.decodeRequest(
        Interface,
        &server_objects,
        message,
        &received_fds,
    );
    try std.testing.expect(client_request.destructor);
    try std.testing.expect(server_objects.namespace.resolve(client_object) != null);
    try consume(&receive_queue);
    try client_request.finish(protocol, &server_objects, &transmit_queue);
    try std.testing.expect(server_objects.namespace.resolve(client_object) == null);
    message = try firstMessage(&transmit_queue);
    const deleted = try Core.Display.decodeEvent(message, &received_fds);
    try std.testing.expectEqual(client_object.id, switch (deleted) {
        .delete_id => |value| value.id,
        else => unreachable,
    });
    try consume(&transmit_queue);

    const pressured = try server_objects.insertClient(3, &Interface.info, 1, null);
    try Interface.encodeRequest(&receive_queue, pressured.id, .{ .destroy = .{} });
    message = try firstMessage(&receive_queue);
    const pressured_request = try wayring.server.decodeRequest(
        Interface,
        &server_objects,
        message,
        &received_fds,
    );
    try consume(&receive_queue);
    const full = [_]u8{0} ** 64;
    try transmit_queue.enqueue(&full, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        pressured_request.finish(protocol, &server_objects, &transmit_queue),
    );
    try std.testing.expect(server_objects.namespace.resolve(pressured) != null);
    try consume(&transmit_queue);

    const local = try server_objects.createLocal(&Interface.info, 1, null);
    try Interface.encodeRequest(&receive_queue, local.id, .{ .destroy = .{} });
    message = try firstMessage(&receive_queue);
    const local_request = try wayring.server.decodeRequest(
        Interface,
        &server_objects,
        message,
        &received_fds,
    );
    try consume(&receive_queue);
    try local_request.finish(protocol, &server_objects, &transmit_queue);
    try std.testing.expect(server_objects.namespace.resolve(local) == null);
    try std.testing.expectEqual(@as(usize, 0), transmit_queue.queuedBytes());
}

test "generated server admission transacts decoded new IDs" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var receive_queue = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer receive_queue.deinit();
    var object_pool = try wayring.objects.SharedObjectPool.init(std.testing.allocator, 6);
    defer object_pool.deinit(std.testing.allocator);
    var buckets = [_]wayring.objects.SharedObjectBucket{.{}} ** 8;
    var server_objects = try wayring.objects.SharedServerObjects.init(
        &object_pool,
        &buckets,
        1,
        6,
        &Core.Display.info,
        null,
    );
    defer server_objects.deinit();
    var removals: RemovalState = .{};
    server_objects.setRemovalHook(.{ .context = &removals, .notify = removedObject });
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    const Interface = protocol.wp_wayring_test_v1;
    const external: wayring.metadata.Interface = .{
        .name = "wp_external_v1",
        .version = 3,
        .requests = &.{},
        .events = &.{},
    };
    const parent = try server_objects.insertClient(2, &Interface.info, 1, null);
    var local_context: u8 = 1;
    var external_context: u8 = 2;
    var dynamic_context: u8 = 3;

    try Interface.encodeRequest(&receive_queue, parent.id, .{ .construct_children = .{
        .local_child = 3,
        .external_child = 4,
        .dynamic_child = .{
            .interface = Interface.info.name,
            .version = 1,
            .id = parent.id,
        },
    } });
    var decoded = try wayring.server.decodeRequest(
        Interface,
        &server_objects,
        try firstMessage(&receive_queue),
        &received_fds,
    );
    try consume(&receive_queue);
    try std.testing.expectError(error.WrongInterface, Interface.admit_construct_children(
        &server_objects,
        decoded.handle,
        decoded.value.construct_children,
        .{
            .local_child = &local_context,
            .external_child = .{ .interface = &Interface.info },
            .dynamic_child = .{ .interface = &Interface.info },
        },
    ));
    try std.testing.expectEqual(@as(usize, 2), server_objects.namespace.len());
    try std.testing.expectError(error.DuplicateId, Interface.admit_construct_children(
        &server_objects,
        decoded.handle,
        decoded.value.construct_children,
        .{
            .local_child = &local_context,
            .external_child = .{ .interface = &external, .context = &external_context },
            .dynamic_child = .{ .interface = &Interface.info, .context = &dynamic_context },
        },
    ));
    try std.testing.expectEqual(@as(usize, 2), server_objects.namespace.len());
    try std.testing.expect(server_objects.namespace.get(3) == null);
    try std.testing.expect(server_objects.namespace.get(4) == null);
    try std.testing.expectEqual(@as(usize, 0), removals.total);

    try Interface.encodeRequest(&receive_queue, parent.id, .{ .construct_children = .{
        .local_child = 3,
        .external_child = 4,
        .dynamic_child = .{
            .interface = Interface.info.name,
            .version = 1,
            .id = 5,
        },
    } });
    decoded = try wayring.server.decodeRequest(
        Interface,
        &server_objects,
        try firstMessage(&receive_queue),
        &received_fds,
    );
    try consume(&receive_queue);
    const admitted = try Interface.admit_construct_children(
        &server_objects,
        decoded.handle,
        decoded.value.construct_children,
        .{
            .local_child = &local_context,
            .external_child = .{ .interface = &external, .context = &external_context },
            .dynamic_child = .{ .interface = &Interface.info, .context = &dynamic_context },
        },
    );
    const local = server_objects.namespace.resolve(admitted.local_child).?;
    try std.testing.expectEqual(&Interface.info, local.interface);
    try std.testing.expectEqual(@as(?*anyopaque, &local_context), local.context);
    const external_object = server_objects.namespace.resolve(admitted.external_child).?;
    try std.testing.expectEqual(&external, external_object.interface);
    try std.testing.expectEqual(@as(u32, 1), external_object.version);
    try std.testing.expectEqual(@as(?*anyopaque, &external_context), external_object.context);
    const dynamic = server_objects.namespace.resolve(admitted.dynamic_child).?;
    try std.testing.expectEqual(&Interface.info, dynamic.interface);
    try std.testing.expectEqual(@as(?*anyopaque, &dynamic_context), dynamic.context);
}

test "compositor binding creates and destroys a surface resource" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var receive_queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer receive_queue.deinit();
    var transmit_queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer transmit_queue.deinit();
    var object_pool = try wayring.objects.SharedObjectPool.init(std.testing.allocator, 5);
    defer object_pool.deinit(std.testing.allocator);
    var buckets = [_]wayring.objects.SharedObjectBucket{.{}} ** 8;
    var server_objects = try wayring.objects.SharedServerObjects.init(
        &object_pool,
        &buckets,
        1,
        5,
        &Core.Display.info,
        null,
    );
    defer server_objects.deinit();
    var removals: RemovalState = .{};
    server_objects.setRemovalHook(.{ .context = &removals, .notify = removedObject });
    var globals = try wayring.server.Globals.init(std.testing.allocator, 1);
    defer globals.deinit(std.testing.allocator);
    const global = try globals.add(&protocol.wl_compositor.info, 6, null);
    const compositor = try Core.bindGlobal(&server_objects, &globals, .{ .bind = .{
        .name = global.id,
        .id = .{
            .interface = protocol.wl_compositor.info.name,
            .version = 4,
            .id = 2,
        },
    } });
    var surface_context: u8 = 1;
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    try protocol.wl_compositor.encodeRequest(&receive_queue, compositor.id, .{
        .create_surface = .{ .id = 3 },
    });
    const create = try wayring.server.decodeRequest(
        protocol.wl_compositor,
        &server_objects,
        try firstMessage(&receive_queue),
        &received_fds,
    );
    try consume(&receive_queue);
    const admitted = try protocol.wl_compositor.admit_create_surface(
        &server_objects,
        create.handle,
        create.value.create_surface,
        .{ .id = &surface_context },
    );
    const surface = server_objects.namespace.resolve(admitted.id).?;
    try std.testing.expectEqual(&protocol.wl_surface.info, surface.interface);
    try std.testing.expectEqual(@as(u32, 4), surface.version);
    try std.testing.expectEqual(@as(?*anyopaque, &surface_context), surface.context);

    try protocol.wl_surface.encodeRequest(&receive_queue, admitted.id.id, .{
        .destroy = .{},
    });
    const destroy = try wayring.server.decodeRequest(
        protocol.wl_surface,
        &server_objects,
        try firstMessage(&receive_queue),
        &received_fds,
    );
    try consume(&receive_queue);
    try destroy.finish(protocol, &server_objects, &transmit_queue);
    try std.testing.expect(server_objects.namespace.resolve(admitted.id) == null);
    try std.testing.expectEqual(@as(usize, 1), removals.total);
    const deleted = try Core.Display.decodeEvent(
        try firstMessage(&transmit_queue),
        &received_fds,
    );
    try std.testing.expectEqual(admitted.id.id, switch (deleted) {
        .delete_id => |value| value.id,
        else => unreachable,
    });
    try consume(&transmit_queue);
}

test "generic server events commit generated destructor lifecycle atomically" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 3);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer queue.deinit();
    var object_pool = try wayring.objects.SharedObjectPool.init(std.testing.allocator, 4);
    defer object_pool.deinit(std.testing.allocator);
    var buckets = [_]wayring.objects.SharedObjectBucket{.{}} ** 8;
    var server_objects = try wayring.objects.SharedServerObjects.init(
        &object_pool,
        &buckets,
        1,
        4,
        &Core.Display.info,
        null,
    );
    defer server_objects.deinit();
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    const callback = try server_objects.insertClient(2, &Core.Callback.info, 1, null);
    const pressure = [_]u8{0} ** 44;
    try queue.enqueue(&pressure, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        wayring.server.sendEvent(
            protocol,
            Core.Callback,
            &server_objects,
            &queue,
            callback,
            .{ .done = .{ .callback_data = 51 } },
        ),
    );
    try std.testing.expectEqual(pressure.len, queue.queuedBytes());
    try std.testing.expect(server_objects.namespace.resolve(callback) != null);
    try consume(&queue);

    try wayring.server.sendEvent(
        protocol,
        Core.Callback,
        &server_objects,
        &queue,
        callback,
        .{ .done = .{ .callback_data = 51 } },
    );
    var message = try firstMessage(&queue);
    try std.testing.expectEqual(
        try Core.Callback.eventSize(.{ .done = .{ .callback_data = 51 } }),
        message.header.size,
    );
    const done = try Core.Callback.decodeEvent(message, &received_fds);
    try std.testing.expectEqual(@as(u32, 51), switch (done) {
        .done => |value| value.callback_data,
    });
    const snapshot = try queue.snapshot(&.{}, &.{});
    const deleted_message = (try wayring.wire.Message.decode(
        snapshot.first[message.header.size..],
    )).?;
    const deleted = try Core.Display.decodeEvent(deleted_message, &received_fds);
    try std.testing.expectEqual(callback.id, switch (deleted) {
        .delete_id => |value| value.id,
        else => unreachable,
    });
    try std.testing.expect(server_objects.namespace.resolve(callback) == null);
    try consume(&queue);

    const local = try server_objects.createLocal(&Core.Callback.info, 1, null);
    try wayring.server.sendEvent(
        protocol,
        Core.Callback,
        &server_objects,
        &queue,
        local,
        .{ .done = .{ .callback_data = 73 } },
    );
    message = try firstMessage(&queue);
    try std.testing.expectEqual(local.id, message.header.object_id);
    try std.testing.expectEqual(@as(usize, 12), queue.queuedBytes());
    try std.testing.expect(server_objects.namespace.resolve(local) == null);
}

test "core server queues a terminal display error before close" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var fragment_storage: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(
        0,
        1,
        &fragment_storage,
        &descriptors,
        0,
        &blocks,
        128,
        0,
    );
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    try Core.postError(&actor, 7, 3, "invalid request");
    try std.testing.expectEqual(wayring.connection.Lifecycle.draining, actor.lifecycle);
    try std.testing.expect(!actor.canDispatch());
    const message = try firstMessage(&actor.transmit);
    const display_event = try Core.Display.decodeEvent(message, &received_fds);
    const protocol_error = switch (display_event) {
        .@"error" => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(?u32, 7), protocol_error.object_id);
    try std.testing.expectEqual(@as(u32, 3), protocol_error.code);
    try std.testing.expectEqualStrings("invalid request", protocol_error.message);

    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try actor.transmit.snapshot(&descriptor_scratch, &control);
    const token = try actor.beginSend(snapshot);
    _ = try actor.complete(.{
        .user_data = token,
        .res = @intCast(snapshot.byteCount()),
        .flags = 0,
    });
    try std.testing.expectEqual(wayring.connection.Lifecycle.closing, actor.lifecycle);
    actor.deinit();
}

test "server dispatch turns invalid requests into terminal display errors" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var fragment_storage: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(
        0,
        1,
        &fragment_storage,
        &descriptors,
        0,
        &blocks,
        128,
        0,
    );
    var namespace = try wayring.objects.Namespace.init(std.testing.allocator, 1);
    defer namespace.deinit(std.testing.allocator);
    _ = try namespace.insert(wayring.objects.display_id, &Core.Display.info, 1, null);

    var frame: [wayring.wire.header_len]u8 = undefined;
    try (wayring.wire.Header{
        .object_id = 99,
        .opcode = 0,
        .size = wayring.wire.header_len,
    }).encode(&frame);
    var bytes: []const u8 = &frame;
    var handler: UnreachableServerHandler = .{};
    const failure = switch (Core.dispatchRequests(
        &actor,
        &namespace,
        &bytes,
        &handler,
    )) {
        .terminal => |value| value,
        .dispatched => return error.ExpectedProtocolError,
    };
    try std.testing.expectEqual(@as(usize, 0), failure.dispatched);
    try std.testing.expectEqual(@as(?u32, 99), failure.object_id);
    try std.testing.expectEqual(error.UnknownObject, failure.cause);
    try std.testing.expect(failure.error_queued);
    try std.testing.expectEqual(wayring.connection.Lifecycle.draining, actor.lifecycle);

    const message = try firstMessage(&actor.transmit);
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    const display_event = try Core.Display.decodeEvent(message, &received_fds);
    const protocol_error = switch (display_event) {
        .@"error" => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(?u32, 99), protocol_error.object_id);
    try std.testing.expectEqual(@as(u32, 0), protocol_error.code);
    try std.testing.expectEqualStrings("UnknownObject", protocol_error.message);

    try consume(&actor.transmit);
    actor.beginClose();
    actor.deinit();
}

const UnreachableServerHandler = struct {
    pub fn request(
        _: *UnreachableServerHandler,
        _: wayring.objects.Dispatch,
        _: wayring.wire.Message,
        _: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        return error.UnexpectedDispatch;
    }
};

test "shared clients preserve admission capacity under object pressure" {
    const allocator = std.testing.allocator;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .max_connections = 2,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 4,
        .receive_control_capacity = 256,
        .fragment_block_size = 64,
        .fragment_block_count = 2,
        .transmit_block_size = 64,
        .transmit_block_count = 2,
        .descriptor_count = 4,
        .send_descriptor_capacity = 2,
    });
    defer reactor.deinit(allocator);
    const SharedClients = wayring.server.SharedClients(protocol);
    var clients = try SharedClients.init(allocator, &reactor, 4, 4, 4);
    defer clients.deinit(allocator);
    const actor_config: wayring.io_uring.ActorConfig = .{
        .received_fd_budget = 2,
        .transmit_byte_budget = 64,
        .transmit_fd_budget = 2,
    };

    var first_sockets: [2]linux.fd_t = undefined;
    try expectSocketPair(&first_sockets);
    defer _ = linux.close(first_sockets[1]);
    const first = try clients.admit(
        .{ .fd = first_sockets[0], .more = true },
        actor_config,
        null,
    );
    const identity = try clients.getCredentials(first);
    try std.testing.expectEqual(linux.getpid(), identity.pid);
    try std.testing.expectEqual(linux.getuid(), identity.uid);
    try std.testing.expectEqual(linux.getgid(), identity.gid);
    const first_objects = try clients.get(first);
    _ = try first_objects.insertClient(2, &protocol.wp_wayring_test_v1.info, 1, null);
    _ = try first_objects.insertClient(3, &protocol.wp_wayring_test_v1.info, 1, null);
    try std.testing.expectError(
        error.Full,
        first_objects.insertClient(4, &protocol.wp_wayring_test_v1.info, 1, null),
    );

    var second_sockets: [2]linux.fd_t = undefined;
    try expectSocketPair(&second_sockets);
    defer _ = linux.close(second_sockets[1]);
    const second = try clients.admit(
        .{ .fd = second_sockets[0], .more = true },
        actor_config,
        null,
    );
    try std.testing.expectEqual(@as(usize, 0), clients.object_pool.available());
    _ = try reactor.ring.submit();

    try stopPeers(&reactor, &.{ first, second });
    try clients.destroy(first);
    try std.testing.expectError(error.SlotInactive, clients.get(first));
    try std.testing.expectError(error.SlotInactive, clients.getCredentials(first));
    try clients.destroy(second);
    try std.testing.expectEqual(@as(usize, 4), clients.object_pool.available());
}

test "server endpoint owns filesystem listener and multishot shutdown" {
    var path_storage: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "/tmp/wayring-endpoint-test-{d}",
        .{linux.getpid()},
    );
    wayring.unix_socket.unlink(path) catch |err| if (err != error.NotFound) return err;
    defer wayring.unix_socket.unlink(path) catch {};
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 16 }, .{
        .max_connections = 2,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 4,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 2,
        .transmit_block_size = 64,
        .transmit_block_count = 2,
        .descriptor_count = 4,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(std.testing.allocator);
    const listener_fd = try wayring.unix_socket.listen(path, 4);
    var runtime = try wayring.server.Runtime(protocol).init(
        std.testing.allocator,
        &reactor,
        listener_fd,
        .{
            .actor = .{
                .received_fd_budget = 1,
                .transmit_byte_budget = 64,
                .transmit_fd_budget = 1,
            },
            .object_capacity = 6,
            .object_quota = 3,
            .buckets_per_client = 8,
            .max_globals = 2,
            .registry_capacity = 3,
        },
    );
    var bind_state: BindState = .{};
    const initial_global = try runtime.globals.addWithBinder(
        &protocol.wp_wayring_test_v1.info,
        1,
        &bind_state,
        activateGlobal,
    );
    try runtime.prepareAccept();
    const client_fds: [2]linux.fd_t = .{
        try wayring.unix_socket.connect(path),
        try wayring.unix_socket.connect(path),
    };
    defer {
        for (client_fds) |fd| _ = linux.close(fd);
    }
    _ = try reactor.ring.submit();

    var accepted_peers: [2]wayring.io_uring.Peer = undefined;
    for (&accepted_peers) |*peer| {
        const accept_completion = try reactor.ring.copy_cqe();
        try std.testing.expectEqual(
            wayring.io_uring.CompletionTarget.listener,
            reactor.route(&runtime.endpoint.listener, accept_completion).?,
        );
        peer.* = (try runtime.completeListener(accept_completion, null)) orelse
            return error.UnexpectedCompletion;
    }
    var removal_states: [2]RemovalState = .{ .{}, .{} };
    for (accepted_peers, &removal_states) |peer, *state| try runtime.setRemovalHook(
        peer,
        .{ .context = state, .notify = removedObject },
    );
    var active_peers = runtime.clients.iterator();
    for (accepted_peers) |peer| try std.testing.expectEqual(peer, active_peers.next().?);
    try std.testing.expectEqual(null, active_peers.next());

    var get_registry_bytes: [12]u8 = undefined;
    try (wayring.wire.Header{
        .object_id = wayring.objects.display_id,
        .opcode = 1,
        .size = get_registry_bytes.len,
    }).encode(get_registry_bytes[0..wayring.wire.header_len]);
    std.mem.writeInt(
        u32,
        get_registry_bytes[wayring.wire.header_len..],
        2,
        @import("builtin").cpu.arch.endian(),
    );
    const get_registry = (try wayring.wire.Message.decode(&get_registry_bytes)).?;
    var registries: [2]wayring.objects.Handle = undefined;
    for (accepted_peers, &registries) |peer, *registry| {
        const actor = try reactor.getActor(peer);
        registry.* = switch (try runtime.decodeDisplayRequest(
            peer,
            get_registry,
            &actor.received_fds,
            null,
        )) {
            .get_registry => |value| value,
            else => unreachable,
        };
    }

    const first_binding: Core.Registry.Request = .{ .bind = .{
        .name = initial_global.id,
        .id = .{
            .interface = protocol.wp_wayring_test_v1.info.name,
            .version = 1,
            .id = 4,
        },
    } };
    const bound = try runtime.bindGlobal(accepted_peers[0], first_binding);
    try std.testing.expectEqual(@as(u32, 4), bound.id);
    try std.testing.expectEqual(accepted_peers[0], bind_state.last.?.peer);
    try std.testing.expectEqual(linux.getpid(), bind_state.last.?.credentials.pid);
    try std.testing.expectEqual(initial_global, bind_state.last.?.global);
    try std.testing.expectEqual(bound, bind_state.last.?.resource);
    try std.testing.expectEqual(
        @as(?*anyopaque, &bind_state.resource_context),
        (try runtime.clients.get(accepted_peers[0])).namespace.resolve(bound).?.context,
    );
    _ = try (try runtime.clients.get(accepted_peers[0])).removeClient(bound);
    try std.testing.expectEqual(@as(usize, 1), removal_states[0].resources);

    bind_state.fail = true;
    try std.testing.expectError(
        error.ActivationFailed,
        runtime.bindGlobal(accepted_peers[0], first_binding),
    );
    bind_state.fail = false;
    try std.testing.expect(
        (try runtime.clients.get(accepted_peers[0])).namespace.get(4) == null,
    );
    try std.testing.expectEqual(@as(usize, 1), removal_states[0].resources);
    const second_bound = try runtime.bindGlobal(accepted_peers[1], first_binding);
    try std.testing.expectEqual(@as(u32, 4), second_bound.id);

    const full = [_]u8{0} ** 64;
    try (try reactor.getActor(accepted_peers[0])).transmit.enqueue(&full, &.{});
    try std.testing.expectError(
        error.GlobalUpdateActive,
        runtime.addGlobal(&protocol.wp_wayring_test_v1.info, 1, null),
    );
    try std.testing.expectEqual(
        accepted_peers[0],
        (try runtime.publishNext()).blocked,
    );
    try consume(&(try reactor.getActor(accepted_peers[0])).transmit);
    for (accepted_peers, registries) |peer, registry| {
        try std.testing.expectEqual(peer, (try runtime.publishNext()).sent);
        const actor = try reactor.getActor(peer);
        const message = try firstMessage(&actor.transmit);
        try std.testing.expectEqual(registry.id, message.header.object_id);
        const event = try Core.Registry.decodeEvent(message, &actor.received_fds);
        try std.testing.expectEqual(initial_global.id, switch (event) {
            .global => |value| value.name,
            else => unreachable,
        });
        try consume(&actor.transmit);
    }
    try std.testing.expectEqual(
        wayring.server.Runtime(protocol).PublishResult.complete,
        try runtime.publishNext(),
    );

    try (try reactor.getActor(accepted_peers[0])).transmit.enqueue(&full, &.{});
    const added = try runtime.addGlobal(&protocol.wp_wayring_test_v1.info, 1, null);
    try std.testing.expectError(
        error.GlobalUpdateActive,
        runtime.addGlobal(&protocol.wp_wayring_test_v1.info, 1, null),
    );
    try std.testing.expectError(error.GlobalUpdateActive, runtime.removeGlobal(added));
    std.mem.writeInt(
        u32,
        get_registry_bytes[wayring.wire.header_len..],
        3,
        @import("builtin").cpu.arch.endian(),
    );
    const late_registry = switch (try runtime.decodeDisplayRequest(
        accepted_peers[0],
        (try wayring.wire.Message.decode(&get_registry_bytes)).?,
        &(try reactor.getActor(accepted_peers[0])).received_fds,
        null,
    )) {
        .get_registry => |value| value,
        else => unreachable,
    };
    try std.testing.expectError(error.Full, runtime.decodeDisplayRequest(
        accepted_peers[1],
        (try wayring.wire.Message.decode(&get_registry_bytes)).?,
        &(try reactor.getActor(accepted_peers[1])).received_fds,
        null,
    ));
    try std.testing.expect(
        (try runtime.clients.get(accepted_peers[1])).namespace.get(3) == null,
    );
    try std.testing.expectEqual(
        accepted_peers[0],
        (try runtime.publishNext()).blocked,
    );
    try consume(&(try reactor.getActor(accepted_peers[0])).transmit);
    for (accepted_peers) |peer| try std.testing.expectEqual(
        peer,
        (try runtime.publishNext()).sent,
    );
    try std.testing.expectEqual(
        accepted_peers[0],
        (try runtime.publishNext()).blocked,
    );
    try std.testing.expectError(
        error.GlobalUpdateActive,
        runtime.addGlobal(&protocol.wp_wayring_test_v1.info, 1, null),
    );
    for (accepted_peers, registries) |peer, registry| {
        const actor = try reactor.getActor(peer);
        const global_event = try Core.Registry.decodeEvent(
            try firstMessage(&actor.transmit),
            &actor.received_fds,
        );
        const global = switch (global_event) {
            .global => |value| value,
            else => unreachable,
        };
        try std.testing.expectEqual(added.id, global.name);
        try std.testing.expectEqualStrings("wp_wayring_test_v1", global.interface);
        try std.testing.expectEqual(registry.id, (try firstMessage(&actor.transmit)).header.object_id);
        try consume(&actor.transmit);
    }

    const first_actor = try reactor.getActor(accepted_peers[0]);
    var saw_initial = false;
    var saw_added = false;
    for (0..2) |_| {
        try std.testing.expectEqual(
            accepted_peers[0],
            (try runtime.publishNext()).sent,
        );
        const initial_message = try firstMessage(&first_actor.transmit);
        try std.testing.expectEqual(late_registry.id, initial_message.header.object_id);
        const initial_event = try Core.Registry.decodeEvent(
            initial_message,
            &first_actor.received_fds,
        );
        const name = switch (initial_event) {
            .global => |value| value.name,
            else => unreachable,
        };
        if (name == initial_global.id) saw_initial = true;
        if (name == added.id) saw_added = true;
        try consume(&first_actor.transmit);
    }
    try std.testing.expect(saw_initial);
    try std.testing.expect(saw_added);
    try std.testing.expectEqual(
        wayring.server.Runtime(protocol).PublishResult.complete,
        try runtime.publishNext(),
    );

    try runtime.removeGlobal(added);
    const removal_peers = [_]wayring.io_uring.Peer{
        accepted_peers[0],
        accepted_peers[0],
        accepted_peers[1],
    };
    const removal_registries = [_]wayring.objects.Handle{
        registries[0],
        late_registry,
        registries[1],
    };
    for (removal_peers, removal_registries) |peer, registry| {
        try std.testing.expectEqual(peer, (try runtime.publishNext()).sent);
        const actor = try reactor.getActor(peer);
        const message = try firstMessage(&actor.transmit);
        try std.testing.expectEqual(registry.id, message.header.object_id);
        const remove_event = try Core.Registry.decodeEvent(message, &actor.received_fds);
        try std.testing.expectEqual(added.id, switch (remove_event) {
            .global_remove => |value| value.name,
            else => unreachable,
        });
        try consume(&actor.transmit);
    }
    try std.testing.expectEqual(
        wayring.server.Runtime(protocol).PublishResult.complete,
        try runtime.publishNext(),
    );

    _ = try runtime.prepareEndpointClose();
    for (accepted_peers) |peer| _ = try runtime.clients.prepareClose(peer);
    _ = try reactor.ring.submit();
    while (!runtime.endpoint.listener.canDeinit() or
        !(try reactor.getActor(accepted_peers[0])).canDeinit() or
        !(try reactor.getActor(accepted_peers[1])).canDeinit())
    {
        const completion = try reactor.ring.copy_cqe();
        switch (reactor.route(&runtime.endpoint.listener, completion) orelse
            return error.UnexpectedCompletion) {
            .listener => if (try runtime.completeListener(completion, null) != null)
                return error.UnexpectedCompletion,
            .connection => |routed| {
                const peer = reactor.routedPeer(routed);
                const actor = try reactor.getActor(peer);
                const event = try actor.completeRouted(routed.operation, completion);
                switch (event) {
                    .received => try (try reactor.getReceiver(peer)).buffers.put(completion),
                    .receive_stopped, .buffers_exhausted, .cancel_complete, .disconnected => {},
                    else => return error.UnexpectedCompletion,
                }
            },
        }
    }
    for (accepted_peers) |peer| try runtime.destroyClient(peer);
    try std.testing.expectEqual(@as(usize, 4), removal_states[0].total);
    try std.testing.expectEqual(@as(usize, 1), removal_states[0].resources);
    try std.testing.expectEqual(@as(usize, 3), removal_states[1].total);
    try std.testing.expectEqual(@as(usize, 1), removal_states[1].resources);
    try runtime.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(listener_fd, linux.F.GETFD, 0)),
    );
}

const BindState = struct {
    fail: bool = false,
    calls: usize = 0,
    resource_context: u8 = 0,
    last: ?wayring.server.Binding = null,
};

fn activateGlobal(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
    const state: *BindState = @ptrCast(@alignCast(context.?));
    state.calls += 1;
    state.last = binding;
    if (state.fail) return error.ActivationFailed;
    return &state.resource_context;
}

const RemovalState = struct {
    total: usize = 0,
    resources: usize = 0,
};

fn removedObject(context: ?*anyopaque, _: wayring.objects.Handle, object: wayring.objects.Object) void {
    const state: *RemovalState = @ptrCast(@alignCast(context.?));
    state.total += 1;
    if (object.interface == &protocol.wp_wayring_test_v1.info) state.resources += 1;
}

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

fn expectSocketPair(sockets: *[2]linux.fd_t) !void {
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        sockets,
    )));
}

fn stopPeers(
    reactor: *wayring.io_uring.Reactor,
    peers: []const wayring.io_uring.Peer,
) !void {
    for (peers) |peer| _ = try reactor.prepareClose(peer);
    _ = try reactor.ring.submit();
    var remaining = peers.len;
    while (remaining != 0) {
        const completion = try reactor.ring.copy_cqe();
        const routed = reactor.route(null, completion).?.connection;
        const peer = reactor.routedPeer(routed);
        const actor = try reactor.getActor(peer);
        const was_ready = actor.canDeinit();
        const event = try actor.completeRouted(routed.operation, completion);
        switch (routed.operation) {
            .receive => switch (event) {
                .receive_stopped, .disconnected, .buffers_exhausted => {},
                .received => try (try reactor.getReceiver(peer)).buffers.put(completion),
                else => return error.UnexpectedCompletion,
            },
            .cancel => {},
            else => return error.UnexpectedCompletion,
        }
        if (!was_ready and actor.canDeinit()) remaining -= 1;
    }
}
