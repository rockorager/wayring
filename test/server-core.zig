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
    try Interface.encodeRequest(&receive_queue, client_object.id, .{
        .set_target = .{ .target = 99 },
    });
    try std.testing.expectError(
        error.UnknownObject,
        wayring.server.decodeRequest(
            Interface,
            &server_objects,
            try firstMessage(&receive_queue),
            &received_fds,
        ),
    );
    try consume(&receive_queue);
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

test "generated server events transact peer object creation" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var transmit_queue = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer transmit_queue.deinit();
    var object_pool = try wayring.objects.SharedObjectPool.init(std.testing.allocator, 8);
    defer object_pool.deinit(std.testing.allocator);
    var buckets = [_]wayring.objects.SharedObjectBucket{.{}} ** 8;
    var server_objects = try wayring.objects.SharedServerObjects.init(
        &object_pool,
        &buckets,
        1,
        8,
        &Core.Display.info,
        null,
    );
    defer server_objects.deinit();
    var removals: RemovalState = .{};
    server_objects.setRemovalHook(.{ .context = &removals, .notify = removedObject });
    var client_objects = try wayring.objects.ClientObjects.init(
        std.testing.allocator,
        6,
        2,
        &Core.Display.info,
        null,
    );
    defer client_objects.deinit(std.testing.allocator);
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    const Interface = protocol.wp_wayring_test_v1;
    const external: wayring.metadata.Interface = .{
        .name = "wp_external_v1",
        .version = 3,
        .requests = &.{},
        .events = &.{},
    };
    const server_parent = try server_objects.insertClient(2, &Interface.info, 1, null);
    const client_parent = try client_objects.createLocal(&Interface.info, 1, null);
    var local_context: u8 = 1;
    var external_context: u8 = 2;
    var dynamic_context: u8 = 3;

    const full = [_]u8{0} ** 128;
    try transmit_queue.enqueue(&full, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        Interface.construct_event_spawn_children(
            protocol,
            &server_objects,
            &transmit_queue,
            server_parent,
            .{
                .local_child = .{ .context = &local_context },
                .external_child = .{ .interface = &external, .context = &external_context },
                .dynamic_child = .{
                    .interface = &Interface.info,
                    .version = 1,
                    .context = &dynamic_context,
                },
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), server_objects.namespace.len());
    try std.testing.expectEqual(@as(usize, 0), removals.total);
    try consume(&transmit_queue);

    const constructed = try Interface.construct_event_spawn_children(
        protocol,
        &server_objects,
        &transmit_queue,
        server_parent,
        .{
            .local_child = .{ .context = &local_context },
            .external_child = .{ .interface = &external, .context = &external_context },
            .dynamic_child = .{
                .interface = &Interface.info,
                .version = 1,
                .context = &dynamic_context,
            },
        },
    );
    const message = try firstMessage(&transmit_queue);
    const event = try wayring.client.decodeEvent(
        Interface,
        &client_objects,
        client_parent,
        message,
        &received_fds,
    );
    const payload = switch (event) {
        .spawn_children => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(constructed.local_child.id, payload.local_child);
    try std.testing.expectEqual(constructed.external_child.id, payload.external_child);
    try std.testing.expectEqual(constructed.dynamic_child.id, payload.dynamic_child.id);

    const occupied = try client_objects.insertPeer(
        constructed.external_child.id,
        &external,
        1,
        null,
    );
    try std.testing.expectError(
        error.DuplicateId,
        Interface.admit_event_spawn_children(
            &client_objects,
            client_parent,
            payload,
            .{
                .local_child = &local_context,
                .external_child = .{ .interface = &external, .context = &external_context },
                .dynamic_child = .{ .interface = &Interface.info, .context = &dynamic_context },
            },
        ),
    );
    try std.testing.expect(client_objects.namespace.get(constructed.local_child.id) == null);
    _ = try client_objects.removePeer(occupied);

    const admitted = try Interface.admit_event_spawn_children(
        &client_objects,
        client_parent,
        payload,
        .{
            .local_child = &local_context,
            .external_child = .{ .interface = &external, .context = &external_context },
            .dynamic_child = .{ .interface = &Interface.info, .context = &dynamic_context },
        },
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, &local_context),
        client_objects.namespace.resolve(admitted.local_child).?.context,
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, &external_context),
        client_objects.namespace.resolve(admitted.external_child).?.context,
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, &dynamic_context),
        client_objects.namespace.resolve(admitted.dynamic_child).?.context,
    );
    try consume(&transmit_queue);
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
    try std.testing.expectEqual(wayring.connection.Lifecycle.draining, actor.lifecycle());
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
    try std.testing.expectEqual(wayring.connection.Lifecycle.closing, actor.lifecycle());
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
    try std.testing.expectEqual(wayring.connection.Lifecycle.draining, actor.lifecycle());

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

test "client stores accept stateless and stateful allocators" {
    inline for (.{ std.heap.page_allocator, std.testing.allocator }) |allocator| {
        // Empty store initialization and teardown do not access the reactor.
        var reactor: wayring.io_uring.Reactor = undefined;
        var clients = try wayring.server.SharedClients(protocol).init(allocator, &reactor, 1, 1, 2);
        clients.deinit(allocator);
    }
}

test "clients keep independent bounded object namespaces" {
    const allocator = std.testing.allocator;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
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
    _ = try first_objects.insertClient(4, &protocol.wp_wayring_test_v1.info, 1, null);
    try std.testing.expectError(
        error.Full,
        first_objects.insertClient(5, &protocol.wp_wayring_test_v1.info, 1, null),
    );

    var second_sockets: [2]linux.fd_t = undefined;
    try expectSocketPair(&second_sockets);
    defer _ = linux.close(second_sockets[1]);
    const second = try clients.admit(
        .{ .fd = second_sockets[0], .more = true },
        actor_config,
        null,
    );
    _ = try reactor.ring.submit();

    try stopPeers(&reactor, &.{ first, second });
    try clients.destroy(first);
    try std.testing.expectError(error.SlotInactive, clients.get(first));
    try std.testing.expectError(error.SlotInactive, clients.getCredentials(first));
    try clients.destroy(second);
}

test "client admission grows beyond initial object reserve" {
    const allocator = std.testing.allocator;
    const client_count = 16;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 64 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = 4,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 2,
        .transmit_block_size = 64,
        .transmit_block_count = 2,
        .descriptor_count = 2,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(allocator);
    const SharedClients = wayring.server.SharedClients(protocol);
    var clients = try SharedClients.init(allocator, &reactor, 1, 4, 4);
    defer clients.deinit(allocator);
    const actor_config: wayring.io_uring.ActorConfig = .{
        .received_fd_budget = 1,
        .transmit_byte_budget = 64,
        .transmit_fd_budget = 1,
    };
    var peers: [client_count]wayring.io_uring.Peer = undefined;
    var remotes = [_]linux.fd_t{-1} ** client_count;
    defer {
        for (remotes) |remote| {
            if (remote >= 0) _ = linux.close(remote);
        }
    }
    for (&peers, &remotes) |*peer, *remote| {
        var sockets: [2]linux.fd_t = undefined;
        try expectSocketPair(&sockets);
        peer.* = try clients.admit(
            .{ .fd = sockets[0], .more = true },
            actor_config,
            null,
        );
        remote.* = sockets[1];
    }
    try std.testing.expectEqual(@as(usize, client_count), reactor.slots.active_count);
    try std.testing.expectEqual(@as(usize, client_count), clients.object_pool.nodes.items.len);
    _ = try reactor.ring.submit();
    try stopPeers(&reactor, &peers);
    for (peers) |peer| try clients.destroy(peer);
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
    var visibility: VisibilityState = .{};
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
            .global_filter = .{
                .context = &visibility,
                .visible = globalVisible,
            },
        },
    );
    var bind_state: BindState = .{};
    const initial_global = try runtime.globals.addWithBinder(
        &protocol.wp_wayring_test_v1.info,
        1,
        &bind_state,
        activateGlobal,
    );
    const initial_restricted = try runtime.globals.add(
        &protocol.wp_wayring_test_v1.info,
        1,
        &visibility.restricted_context,
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
    visibility.allowed_slot = accepted_peers[0].slot;
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

    var sync_bytes: [12]u8 = undefined;
    try (wayring.wire.Header{
        .object_id = wayring.objects.display_id,
        .opcode = 0,
        .size = sync_bytes.len,
    }).encode(sync_bytes[0..wayring.wire.header_len]);
    std.mem.writeInt(
        u32,
        sync_bytes[wayring.wire.header_len..],
        5,
        @import("builtin").cpu.arch.endian(),
    );
    const first_sync = switch (try runtime.decodeDisplayRequest(
        accepted_peers[0],
        (try wayring.wire.Message.decode(&sync_bytes)).?,
        &(try reactor.getActor(accepted_peers[0])).received_fds,
        null,
    )) {
        .sync => |value| value,
        else => unreachable,
    };
    try runtime.completeSync(accepted_peers[0], first_sync, 91);

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
    var saw_public = false;
    var saw_restricted = false;
    for (0..2) |_| {
        try std.testing.expectEqual(accepted_peers[0], (try runtime.publishNext()).sent);
        const actor = try reactor.getActor(accepted_peers[0]);
        const message = try firstMessage(&actor.transmit);
        try std.testing.expectEqual(registries[0].id, message.header.object_id);
        const event = try Core.Registry.decodeEvent(message, &actor.received_fds);
        const name = switch (event) {
            .global => |value| value.name,
            else => unreachable,
        };
        if (name == initial_global.id) saw_public = true;
        if (name == initial_restricted.id) saw_restricted = true;
        try consume(&actor.transmit);
    }
    try std.testing.expect(saw_public);
    try std.testing.expect(saw_restricted);

    try (try reactor.getActor(accepted_peers[0])).transmit.enqueue(&full, &.{});
    try std.testing.expectEqual(
        accepted_peers[0],
        (try runtime.publishNext()).blocked,
    );
    try std.testing.expect(
        (try runtime.clients.get(accepted_peers[0])).namespace.resolve(first_sync) != null,
    );
    try consume(&(try reactor.getActor(accepted_peers[0])).transmit);
    try std.testing.expectEqual(accepted_peers[0], (try runtime.publishNext()).sent);
    const first_sync_message = try firstMessage(&(try reactor.getActor(accepted_peers[0])).transmit);
    try std.testing.expectEqual(first_sync.id, first_sync_message.header.object_id);
    const first_sync_done = try Core.Callback.decodeEvent(
        first_sync_message,
        &(try reactor.getActor(accepted_peers[0])).received_fds,
    );
    try std.testing.expectEqual(@as(u32, 91), switch (first_sync_done) {
        .done => |value| value.callback_data,
    });
    try std.testing.expect(
        (try runtime.clients.get(accepted_peers[0])).namespace.resolve(first_sync) == null,
    );
    try consume(&(try reactor.getActor(accepted_peers[0])).transmit);

    try std.testing.expectEqual(accepted_peers[1], (try runtime.publishNext()).sent);
    const second_initial_actor = try reactor.getActor(accepted_peers[1]);
    const second_initial = try Core.Registry.decodeEvent(
        try firstMessage(&second_initial_actor.transmit),
        &second_initial_actor.received_fds,
    );
    try std.testing.expectEqual(initial_global.id, switch (second_initial) {
        .global => |value| value.name,
        else => unreachable,
    });
    try consume(&second_initial_actor.transmit);
    try std.testing.expectEqual(
        wayring.server.Runtime(protocol).PublishResult.complete,
        try runtime.publishNext(),
    );

    try runtime.removeGlobal(initial_restricted);
    try std.testing.expectEqual(accepted_peers[0], (try runtime.publishNext()).sent);
    const initial_remove = try Core.Registry.decodeEvent(
        try firstMessage(&(try reactor.getActor(accepted_peers[0])).transmit),
        &(try reactor.getActor(accepted_peers[0])).received_fds,
    );
    try std.testing.expectEqual(initial_restricted.id, switch (initial_remove) {
        .global_remove => |value| value.name,
        else => unreachable,
    });
    try consume(&(try reactor.getActor(accepted_peers[0])).transmit);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(
        accepted_peers[1],
        registries[1],
        initial_restricted.id,
    ));
    try runtime.ackGlobalRemove(accepted_peers[0], registries[0], initial_restricted.id);
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

    visibility.allowed_slot = accepted_peers[0].slot;
    const restricted = try runtime.addGlobal(
        &protocol.wp_wayring_test_v1.info,
        1,
        &visibility.restricted_context,
    );
    for ([_]wayring.objects.Handle{ registries[0], late_registry }) |registry| {
        try std.testing.expectEqual(accepted_peers[0], (try runtime.publishNext()).sent);
        const message = try firstMessage(&first_actor.transmit);
        try std.testing.expectEqual(registry.id, message.header.object_id);
        const event = try Core.Registry.decodeEvent(message, &first_actor.received_fds);
        try std.testing.expectEqual(restricted.id, switch (event) {
            .global => |value| value.name,
            else => unreachable,
        });
        try consume(&first_actor.transmit);
    }
    try std.testing.expectEqual(
        wayring.server.Runtime(protocol).PublishResult.complete,
        try runtime.publishNext(),
    );
    try std.testing.expectError(error.UnknownGlobal, runtime.bindGlobal(
        accepted_peers[1],
        .{ .bind = .{
            .name = restricted.id,
            .id = .{
                .interface = protocol.wp_wayring_test_v1.info.name,
                .version = 1,
                .id = 5,
            },
        } },
    ));

    try runtime.removeGlobal(restricted);
    for ([_]wayring.objects.Handle{ registries[0], late_registry }) |registry| {
        try std.testing.expectEqual(accepted_peers[0], (try runtime.publishNext()).sent);
        const message = try firstMessage(&first_actor.transmit);
        try std.testing.expectEqual(registry.id, message.header.object_id);
        const event = try Core.Registry.decodeEvent(message, &first_actor.received_fds);
        try std.testing.expectEqual(restricted.id, switch (event) {
            .global_remove => |value| value.name,
            else => unreachable,
        });
        try consume(&first_actor.transmit);
    }
    try std.testing.expectEqual(
        wayring.server.Runtime(protocol).PublishResult.complete,
        try runtime.publishNext(),
    );

    try std.testing.expectError(
        error.WrongInterface,
        runtime.removeRegistry(accepted_peers[1], second_bound),
    );
    try std.testing.expectError(
        error.StaleHandle,
        runtime.removeRegistry(accepted_peers[1], late_registry),
    );
    try std.testing.expectError(error.StaleHandle, runtime.removeRegistry(
        accepted_peers[0],
        .{ .id = late_registry.id, .generation = late_registry.generation + 1 },
    ));
    try std.testing.expect(
        (try runtime.clients.get(accepted_peers[0])).namespace.resolve(late_registry) != null,
    );
    try first_actor.transmit.enqueue(&full, &.{});
    try std.testing.expectError(
        error.ByteBudgetExceeded,
        runtime.removeRegistry(accepted_peers[0], late_registry),
    );
    try std.testing.expect(
        (try runtime.clients.get(accepted_peers[0])).namespace.resolve(late_registry) != null,
    );
    try consume(&first_actor.transmit);
    _ = try runtime.removeRegistry(accepted_peers[0], late_registry);
    try std.testing.expect(
        (try runtime.clients.get(accepted_peers[0])).namespace.resolve(late_registry) == null,
    );
    try std.testing.expectEqual(@as(usize, 3), removal_states[0].total);
    const first_delete = try Core.Display.decodeEvent(
        try firstMessage(&first_actor.transmit),
        &first_actor.received_fds,
    );
    try std.testing.expectEqual(late_registry.id, switch (first_delete) {
        .delete_id => |value| value.id,
        else => unreachable,
    });
    try consume(&first_actor.transmit);

    // The removed subscription node and object capacity are both reusable.
    _ = try (try runtime.clients.get(accepted_peers[1])).removeClient(second_bound);
    const replacement_registry = switch (try runtime.decodeDisplayRequest(
        accepted_peers[1],
        (try wayring.wire.Message.decode(&get_registry_bytes)).?,
        &(try reactor.getActor(accepted_peers[1])).received_fds,
        null,
    )) {
        .get_registry => |value| value,
        else => unreachable,
    };
    _ = try runtime.removeRegistry(accepted_peers[1], replacement_registry);
    const replacement_actor = try reactor.getActor(accepted_peers[1]);
    const replacement_delete = try Core.Display.decodeEvent(
        try firstMessage(&replacement_actor.transmit),
        &replacement_actor.received_fds,
    );
    try std.testing.expectEqual(replacement_registry.id, switch (replacement_delete) {
        .delete_id => |value| value.id,
        else => unreachable,
    });
    try consume(&replacement_actor.transmit);

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
    try std.testing.expectEqual(@as(usize, 5), removal_states[0].total);
    try std.testing.expectEqual(@as(usize, 1), removal_states[0].resources);
    try std.testing.expectEqual(@as(usize, 4), removal_states[1].total);
    try std.testing.expectEqual(@as(usize, 1), removal_states[1].resources);
    try runtime.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(listener_fd, linux.F.GETFD, 0)),
    );
}

test "server driver recovers SQ pressure and drains protocol errors" {
    const allocator = std.testing.allocator;
    var path_storage: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "/tmp/wayring-driver-test-{d}",
        .{linux.getpid()},
    );
    wayring.unix_socket.unlink(path) catch |err| if (err != error.NotFound) return err;
    defer wayring.unix_socket.unlink(path) catch {};

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 2,
        .transmit_block_size = 64,
        .transmit_block_count = 2,
        .descriptor_count = 2,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(allocator);
    const listener_fd = try wayring.unix_socket.listen(path, 2);
    var runtime = try wayring.server.Runtime(protocol).init(
        allocator,
        &reactor,
        listener_fd,
        .{
            .actor = .{
                .received_fd_budget = 1,
                .transmit_byte_budget = 64,
                .transmit_fd_budget = 1,
            },
            .object_capacity = 4,
            .object_quota = 2,
            .buckets_per_client = 4,
            .max_globals = 1,
            .registry_capacity = 2,
        },
    );
    defer runtime.deinit(allocator) catch unreachable;
    var driver = try wayring.server.Driver(protocol).init(allocator, &runtime, null);
    defer driver.deinit(allocator);
    var handler: DriverHandler = .{
        .runtime = &runtime,
        .saturate_submission_queue = true,
    };

    try runtime.prepareAccept();
    const client_fds = [2]linux.fd_t{
        try wayring.unix_socket.connect(path),
        try wayring.unix_socket.connect(path),
    };
    _ = try reactor.ring.submit();
    var completions: [2]linux.io_uring_cqe = undefined;
    var completion: linux.io_uring_cqe = undefined;
    var count = try reactor.ring.copy_cqes(&completions, 2);
    var progress = try driver.dispatch(completions[0..count], &handler);
    try std.testing.expectEqual(@as(usize, 2), progress.accepted);
    try std.testing.expectEqual(@as(usize, 2), handler.connected_count);
    _ = try reactor.ring.submit();

    // A later CQE can fail after the actor has consumed it. Preserve that
    // ownership boundary and leave the untouched suffix with the caller.
    var send_completions: [3]wayring.server.Driver(protocol).RoutedCompletion = undefined;
    var peers: [2]wayring.io_uring.Peer = undefined;
    var peer_iterator = runtime.clients.iterator();
    for (&peers) |*peer| peer.* = peer_iterator.next().?;
    for (peers, 0..) |peer, index| {
        const actor = try reactor.getActor(peer);
        try actor.enqueue("x", &.{});
        var descriptor_scratch: [1]linux.fd_t = undefined;
        var control_storage: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const snapshot = try actor.transmit.snapshot(&descriptor_scratch, &control_storage);
        const token = try actor.beginSend(snapshot);
        const cqe: linux.io_uring_cqe = .{
            .user_data = token,
            .res = 1,
            .flags = 0,
        };
        send_completions[index] = .{
            .completion = cqe,
            .target = reactor.route(null, cqe).?,
        };
    }
    send_completions[2] = .{
        .completion = .{ .user_data = 0, .res = 1, .flags = 0 },
        .target = .{ .connection = .{
            .slot = peers[1].slot,
            .operation = .send,
        } },
    };

    driver.pending_storage.shrinkAndFree(allocator, 1);
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 0,
    });
    driver.allocator = failing_allocator.allocator();
    const failed_batch = driver.dispatchRouted(&send_completions, &handler);
    const transferred = switch (failed_batch) {
        .complete => return error.ExpectedDispatchFailure,
        .failed => |failure| failure,
    };
    try std.testing.expectEqual(error.OutOfMemory, transferred.cause);
    try std.testing.expectEqual(
        wayring.server.Driver(protocol).CompletionOwnership.driver,
        transferred.ownership,
    );
    try std.testing.expectEqual(@as(usize, 2), transferred.progress.completions);
    try std.testing.expect(!(try reactor.getActor(peers[1])).transmit.sendActive());

    driver.allocator = allocator;
    const suffix = driver.dispatchRouted(
        send_completions[transferred.progress.completions..],
        &handler,
    );
    const retained = switch (suffix) {
        .complete => return error.ExpectedDispatchFailure,
        .failed => |failure| failure,
    };
    try std.testing.expectEqual(error.NoSendActive, retained.cause);
    try std.testing.expectEqual(
        wayring.server.Driver(protocol).CompletionOwnership.caller,
        retained.ownership,
    );
    try std.testing.expectEqual(@as(usize, 0), retained.progress.completions);
    _ = try driver.schedule(peers[1]);
    _ = try driver.prepare(&handler);

    var request: [12]u8 = undefined;
    try (wayring.wire.Header{
        .object_id = wayring.objects.display_id,
        .opcode = 0,
        .size = request.len,
    }).encode(request[0..wayring.wire.header_len]);
    std.mem.writeInt(
        u32,
        request[wayring.wire.header_len..],
        2,
        @import("builtin").cpu.arch.endian(),
    );
    for (client_fds) |client_fd| try std.testing.expectEqual(
        request.len,
        linux.write(client_fd, &request, request.len),
    );
    count = try reactor.ring.copy_cqes(&completions, 2);
    progress = try driver.dispatch(completions[0..count], &handler);
    try std.testing.expectEqual(@as(usize, 2), progress.requests);
    try std.testing.expectEqual(@as(usize, 0), progress.prepared);
    try std.testing.expect(progress.pending);
    _ = try reactor.ring.submit();
    var completed_nops: usize = 0;
    var pressure_prepared: usize = 0;
    while (completed_nops < handler.queued_nops) {
        completion = try reactor.ring.copy_cqe();
        if (completion.user_data == std.math.maxInt(u64)) {
            completed_nops += 1;
        } else {
            progress = try driver.dispatch(&.{completion}, &handler);
            pressure_prepared += progress.prepared;
        }
    }
    progress = try driver.prepare(&handler);
    pressure_prepared += progress.prepared;
    try std.testing.expect(pressure_prepared >= 2);
    try std.testing.expect(!progress.pending);
    _ = try reactor.ring.submit();

    count = try reactor.ring.copy_cqes(&completions, 2);
    progress = try driver.dispatch(completions[0..count], &handler);
    try std.testing.expectEqual(@as(usize, 0), progress.requests);
    for (client_fds) |client_fd| {
        var response: [24]u8 = undefined;
        try std.testing.expectEqual(
            response.len,
            linux.read(client_fd, &response, response.len),
        );
        const done = (try wayring.wire.Message.decode(&response)).?;
        try std.testing.expectEqual(@as(u32, 2), done.header.object_id);
        const deleted = (try wayring.wire.Message.decode(response[done.header.size..])).?;
        try std.testing.expectEqual(wayring.objects.display_id, deleted.header.object_id);
    }

    var invalid: [wayring.wire.header_len]u8 = undefined;
    try (wayring.wire.Header{
        .object_id = 99,
        .opcode = 0,
        .size = invalid.len,
    }).encode(&invalid);
    try std.testing.expectEqual(
        invalid.len,
        linux.write(client_fds[0], &invalid, invalid.len),
    );
    completion = try reactor.ring.copy_cqe();
    progress = try driver.dispatch(&.{completion}, &handler);
    try std.testing.expectEqual(@as(usize, 1), progress.protocol_errors);
    try std.testing.expectEqual(@as(usize, 1), handler.protocol_error_count);
    try std.testing.expect(progress.prepared != 0);
    _ = try reactor.ring.submit();

    while (handler.disconnected_count == 0) {
        completion = try reactor.ring.copy_cqe();
        progress = try driver.dispatch(&.{completion}, &handler);
        if (progress.prepared != 0 or progress.pending) _ = try reactor.ring.submit();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.disconnected_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.clients.reactor.slots.active_count);
    var error_response: [128]u8 = undefined;
    const error_size = linux.read(client_fds[0], &error_response, error_response.len);
    try std.testing.expect(error_size >= wayring.wire.header_len);
    const display_error = (try wayring.wire.Message.decode(error_response[0..error_size])).?;
    try std.testing.expectEqual(wayring.objects.display_id, display_error.header.object_id);
    try std.testing.expectEqual(@as(u16, 0), display_error.header.opcode);
    _ = linux.close(client_fds[0]);

    try driver.requestShutdown();
    progress = try driver.prepare(&handler);
    if (progress.prepared != 0 or progress.pending) _ = try reactor.ring.submit();
    while (!progress.shutdown_complete) {
        completion = try reactor.ring.copy_cqe();
        progress = try driver.dispatch(&.{completion}, &handler);
        if (progress.prepared != 0 or progress.pending) _ = try reactor.ring.submit();
    }
    try std.testing.expectEqual(@as(usize, 2), handler.disconnected_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.clients.reactor.slots.active_count);
    _ = linux.close(client_fds[1]);
}

test "wl_fixes ack decoding enforces version and registry type" {
    const allocator = std.testing.allocator;
    var server_objects = try wayring.objects.ServerObjects.init(allocator, 8, 2, &Core.Display.info, null);
    defer server_objects.deinit(allocator);
    const registry = try server_objects.insertClient(2, &Core.Registry.info, 1, null);
    _ = try server_objects.insertClient(3, &protocol.wl_fixes.info, 1, null);
    _ = try server_objects.insertClient(4, &protocol.wl_fixes.info, 2, null);
    var blocks = try wayring.pool.SharedBlocks.init(allocator, 64, 2);
    defer blocks.deinit(allocator);
    var descriptors = try wayring.pool.SharedFds.init(allocator, 1);
    defer descriptors.deinit(allocator);
    var queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer queue.deinit();
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    const ack: protocol.wl_fixes.Request = .{ .ack_global_remove = .{ .registry = registry.id, .name = 71 } };
    try protocol.wl_fixes.encodeRequest(&queue, 3, ack);
    try std.testing.expectError(error.UnsupportedVersion, wayring.server.decodeRequest(protocol.wl_fixes, &server_objects, try firstMessage(&queue), &fds));
    try consume(&queue);
    try protocol.wl_fixes.encodeRequest(&queue, 4, ack);
    const decoded = try wayring.server.decodeRequest(protocol.wl_fixes, &server_objects, try firstMessage(&queue), &fds);
    try std.testing.expectEqual(@as(u32, 71), decoded.value.ack_global_remove.name);
    try std.testing.expectEqual(registry.id, decoded.value.ack_global_remove.registry);
    try consume(&queue);
    try protocol.wl_fixes.encodeRequest(&queue, 4, .{ .ack_global_remove = .{ .registry = 3, .name = 71 } });
    try std.testing.expectError(error.WrongInterface, wayring.server.decodeRequest(protocol.wl_fixes, &server_objects, try firstMessage(&queue), &fds));
}

test "global names exhaust rather than alias removed names" {
    var globals = try wayring.server.Globals.init(std.testing.allocator, 1);
    defer globals.deinit(std.testing.allocator);
    globals.next_name = std.math.maxInt(u32);
    const last = try globals.add(&protocol.wp_wayring_test_v1.info, 1, null);
    try std.testing.expectEqual(std.math.maxInt(u32), last.id);
    _ = try globals.remove(last);
    try std.testing.expectError(error.NameExhausted, globals.add(&protocol.wp_wayring_test_v1.info, 1, null));
}

test "removed globals wait for each registry ack or teardown and preserve racing binds" {
    const Runtime = wayring.server.Runtime(protocol);
    const allocator = std.testing.allocator;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = 4,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 2,
        .transmit_block_size = 256,
        .transmit_block_count = 2,
        .descriptor_count = 4,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(allocator);
    var listener: [2]linux.fd_t = undefined;
    try expectSocketPair(&listener);
    defer _ = linux.close(listener[1]);
    var runtime = try Runtime.init(allocator, &reactor, listener[0], .{
        .actor = .{ .received_fd_budget = 1, .transmit_byte_budget = 256, .transmit_fd_budget = 1 },
        .object_capacity = 16,
        .object_quota = 16,
        .buckets_per_client = 16,
        .max_globals = 1,
        .registry_capacity = 1,
    });
    defer runtime.deinit(allocator) catch unreachable;
    var peers: [2]wayring.io_uring.Peer = undefined;
    var remotes: [2]linux.fd_t = undefined;
    for (&peers, &remotes) |*peer, *remote| {
        var sockets: [2]linux.fd_t = undefined;
        try expectSocketPair(&sockets);
        peer.* = try runtime.clients.admit(.{ .fd = sockets[0], .more = true }, runtime.actor_config, null);
        remote.* = sockets[1];
    }
    defer for (remotes) |remote| {
        _ = linux.close(remote);
    };
    _ = try reactor.ring.submit();

    var original: WithdrawalState = .{};
    const global = try runtime.addGlobalWithBinder(&protocol.wp_wayring_test_v1.info, 1, &original, WithdrawalState.bind);
    try drainPublications(&runtime);
    const first = try createRegistry(&runtime, peers[0], 2);
    const second = try createRegistry(&runtime, peers[0], 3);
    const old_client = try createRegistry(&runtime, peers[1], 2);
    try drainPublications(&runtime);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], first, global.id));
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], first, 999));
    try std.testing.expectError(error.WrongInterface, runtime.ackGlobalRemove(
        peers[0],
        (try runtime.clients.get(peers[0])).namespace.lookupHandle(1).?,
        global.id,
    ));

    try runtime.removeGlobalWithCallback(global, WithdrawalState.withdrawn);
    try std.testing.expectEqual(@as(usize, 0), original.withdrawals);
    const request: Core.Registry.Request = .{ .bind = .{
        .name = global.id,
        .id = .{ .interface = protocol.wp_wayring_test_v1.info.name, .version = 1, .id = 8 },
    } };
    const racing = try runtime.bindGlobal(peers[0], request);
    try std.testing.expectEqual(global, original.last.?.global);
    try std.testing.expectEqual(@as(usize, 1), original.binds);
    try std.testing.expectEqual(@as(?*anyopaque, &original.resource), (try runtime.clients.get(peers[0])).namespace.resolve(racing).?.context);
    _ = try (try runtime.clients.get(peers[0])).removeClient(racing);

    // A registry created after removal never inherits a pending offer.
    const late = try createRegistry(&runtime, peers[0], 4);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], late, global.id));
    const actor = try reactor.getActor(peers[0]);
    const full = [_]u8{0} ** 256;
    try actor.transmit.enqueue(&full, &.{});
    try std.testing.expectEqual(peers[0], (try runtime.publishNext()).blocked);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], first, global.id));
    try consume(&actor.transmit);
    try std.testing.expectEqual(peers[0], (try runtime.publishNext()).sent);
    const event_message = try firstMessage(&actor.transmit);
    try std.testing.expectEqual(first.id, event_message.header.object_id);
    try std.testing.expectEqual(global.id, (try Core.Registry.decodeEvent(event_message, &actor.received_fds)).global_remove.name);
    try consume(&actor.transmit);
    try runtime.ackGlobalRemove(peers[0], first, global.id);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], first, global.id));
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], second, global.id));
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[1], old_client, global.id));
    const still_racing = try runtime.bindGlobal(peers[0], request);
    _ = try (try runtime.clients.get(peers[0])).removeClient(still_racing);
    try drainPublications(&runtime);

    // Teardown cannot release an offer if delete_id cannot be queued.
    try actor.transmit.enqueue(&full, &.{});
    try std.testing.expectError(error.ByteBudgetExceeded, runtime.removeRegistry(peers[0], second));
    const blocked_racing = try runtime.bindGlobal(peers[0], request);
    _ = try (try runtime.clients.get(peers[0])).removeClient(blocked_racing);
    try consume(&actor.transmit);
    _ = try runtime.removeRegistry(peers[0], second);
    try consume(&actor.transmit);
    try std.testing.expectError(error.UnknownGlobal, runtime.bindGlobal(peers[0], request));
    try std.testing.expectEqual(@as(usize, 0), original.withdrawals);
    const recycled = try createRegistry(&runtime, peers[0], second.id);
    try std.testing.expect(recycled.generation != second.generation);
    try std.testing.expectError(error.StaleHandle, runtime.ackGlobalRemove(peers[0], second, global.id));
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], recycled, global.id));

    // Retired globals do not occupy active capacity or alias a replacement.
    var replacement: WithdrawalState = .{};
    const next = try runtime.addGlobalWithBinder(&protocol.wp_wayring_test_v1.info, 1, &replacement, WithdrawalState.bind);
    try std.testing.expect(next.id != global.id);
    try drainPublications(&runtime);
    try std.testing.expectError(error.UnknownGlobal, runtime.removeGlobal(global));
    var next_request = request;
    next_request.bind.name = next.id;
    const next_resource = try runtime.bindGlobal(peers[0], next_request);
    try std.testing.expectEqual(next, replacement.last.?.global);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], first, global.id));
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], first, next.id));
    const old_resource = try runtime.bindGlobal(peers[1], request);
    try std.testing.expectEqual(global, original.last.?.global);
    try std.testing.expectEqual(@as(?*anyopaque, &original.resource), (try runtime.clients.get(peers[1])).namespace.resolve(old_resource).?.context);

    // Every offer, including ones never bound, must be acknowledged separately.
    try runtime.removeGlobalWithCallback(next, WithdrawalState.withdrawn);
    for ([_]wayring.objects.Handle{ first, late, recycled }) |registry| {
        try std.testing.expectEqual(peers[0], (try runtime.publishNext()).sent);
        try std.testing.expectEqual(registry.id, (try firstMessage(&actor.transmit)).header.object_id);
        try consume(&actor.transmit);
        try runtime.ackGlobalRemove(peers[0], registry, next.id);
        try std.testing.expectEqual(@as(usize, 0), replacement.withdrawals);
    }
    try std.testing.expectEqual(peers[1], (try runtime.publishNext()).sent);
    try consume(&(try reactor.getActor(peers[1])).transmit);
    try runtime.ackGlobalRemove(peers[1], old_client, next.id);
    try std.testing.expectEqual(@as(usize, 1), replacement.withdrawals);
    try std.testing.expectEqual(next, replacement.withdrawn_handle.?);
    // The final ack may collect the definition before publication's cursor ends.
    try std.testing.expectEqual(Runtime.PublishResult.complete, try runtime.publishNext());
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[1], old_client, next.id));
    try std.testing.expect((try runtime.clients.get(peers[0])).namespace.resolve(next_resource) != null);

    // Registry destruction unlinks a paused removal cursor before node reuse.
    var pending: WithdrawalState = .{};
    const pending_global = try runtime.addGlobal(&protocol.wp_wayring_test_v1.info, 1, &pending);
    try drainPublications(&runtime);
    try runtime.removeGlobalWithCallback(pending_global, WithdrawalState.withdrawn);
    try actor.transmit.enqueue(&full, &.{});
    try std.testing.expectEqual(peers[0], (try runtime.publishNext()).blocked);
    try consume(&actor.transmit);
    _ = try runtime.removeRegistry(peers[0], first);
    try consume(&actor.transmit);
    const recycled_first = try createRegistry(&runtime, peers[0], first.id);
    try drainPublications(&runtime);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(peers[0], recycled_first, pending_global.id));
    try runtime.ackGlobalRemove(peers[0], late, pending_global.id);
    try runtime.ackGlobalRemove(peers[0], recycled, pending_global.id);
    try std.testing.expectEqual(@as(usize, 0), pending.withdrawals);

    // The v1/non-acknowledging client pins both removals until disconnect.
    try stopPeers(&reactor, &peers);
    try runtime.destroyClient(peers[0]);
    try std.testing.expectEqual(@as(usize, 0), original.withdrawals);
    try runtime.destroyClient(peers[1]);
    try std.testing.expectEqual(@as(usize, 1), original.withdrawals);
    try std.testing.expectEqual(@as(usize, 1), pending.withdrawals);
    try std.testing.expectEqual(@as(usize, 1), replacement.withdrawals);

    // No offers means synchronous reclamation, even before publishNext.
    var unoffered: WithdrawalState = .{};
    const unoffered_global = try runtime.addGlobal(&protocol.wp_wayring_test_v1.info, 1, &unoffered);
    try drainPublications(&runtime);
    try runtime.removeGlobalWithCallback(unoffered_global, WithdrawalState.withdrawn);
    try std.testing.expectEqual(@as(usize, 1), unoffered.withdrawals);
    try drainPublications(&runtime);

    // A reused peer slot cannot inherit offers. Destroying its sole registry
    // releases the last offer, even while global_remove publication is pending.
    var sockets: [2]linux.fd_t = undefined;
    try expectSocketPair(&sockets);
    defer _ = linux.close(sockets[1]);
    const reused_peer = try runtime.clients.admit(.{ .fd = sockets[0], .more = true }, runtime.actor_config, null);
    try std.testing.expect(reused_peer.slot == peers[0].slot or reused_peer.slot == peers[1].slot);
    try std.testing.expect(!std.meta.eql(reused_peer, peers[0]) and !std.meta.eql(reused_peer, peers[1]));
    _ = try reactor.ring.submit();
    const sole_registry = try createRegistry(&runtime, reused_peer, 2);
    try std.testing.expectError(error.InvalidAckRemove, runtime.ackGlobalRemove(reused_peer, sole_registry, global.id));
    const stale_peer = if (reused_peer.slot == peers[0].slot) peers[0] else peers[1];
    try std.testing.expectError(error.WrongGeneration, runtime.ackGlobalRemove(stale_peer, old_client, global.id));
    var sole: WithdrawalState = .{};
    const sole_global = try runtime.addGlobal(&protocol.wp_wayring_test_v1.info, 1, &sole);
    try drainPublications(&runtime);
    try runtime.removeGlobalWithCallback(sole_global, WithdrawalState.withdrawn);
    _ = try runtime.removeRegistry(reused_peer, sole_registry);
    try std.testing.expectEqual(@as(usize, 1), sole.withdrawals);
    try consume(&(try reactor.getActor(reused_peer)).transmit);
    try std.testing.expectEqual(Runtime.PublishResult.complete, try runtime.publishNext());
    try stopPeers(&reactor, &.{reused_peer});
    try runtime.destroyClient(reused_peer);
}

const WithdrawalState = struct {
    binds: usize = 0,
    withdrawals: usize = 0,
    last: ?wayring.server.Binding = null,
    withdrawn_handle: ?wayring.objects.Handle = null,
    resource: u8 = 0,

    fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
        const state: *WithdrawalState = @ptrCast(@alignCast(context.?));
        try std.testing.expectEqual(@as(usize, 0), state.withdrawals);
        state.binds += 1;
        state.last = binding;
        return &state.resource;
    }

    fn withdrawn(context: ?*anyopaque, handle: wayring.objects.Handle) void {
        const state: *WithdrawalState = @ptrCast(@alignCast(context.?));
        state.withdrawals += 1;
        state.withdrawn_handle = handle;
    }
};

fn createRegistry(runtime: *wayring.server.Runtime(protocol), peer: wayring.io_uring.Peer, id: u32) !wayring.objects.Handle {
    var bytes: [12]u8 = undefined;
    try (wayring.wire.Header{ .object_id = 1, .opcode = 1, .size = bytes.len }).encode(bytes[0..8]);
    std.mem.writeInt(u32, bytes[8..], id, @import("builtin").cpu.arch.endian());
    return (try runtime.decodeDisplayRequest(peer, (try wayring.wire.Message.decode(&bytes)).?, &(try runtime.clients.reactor.getActor(peer)).received_fds, null)).get_registry;
}

fn drainPublications(runtime: *wayring.server.Runtime(protocol)) !void {
    while (true) switch (try runtime.publishNext()) {
        .sent => |peer| try consume(&(try runtime.clients.reactor.getActor(peer)).transmit),
        .complete => return,
        .blocked => return error.UnexpectedBackpressure,
    };
}

const DriverHandler = struct {
    runtime: *wayring.server.Runtime(protocol),
    saturate_submission_queue: bool = false,
    queued_nops: usize = 0,
    connected_count: usize = 0,
    disconnected_count: usize = 0,
    protocol_error_count: usize = 0,

    pub fn connected(handler: *DriverHandler, _: wayring.io_uring.Peer) void {
        handler.connected_count += 1;
    }

    pub fn disconnected(handler: *DriverHandler, _: wayring.io_uring.Peer) void {
        handler.disconnected_count += 1;
    }

    pub fn protocolError(
        handler: *DriverHandler,
        _: wayring.io_uring.Peer,
        _: Core.RequestFailure,
    ) void {
        handler.protocol_error_count += 1;
    }

    pub fn request(
        handler: *DriverHandler,
        peer: wayring.io_uring.Peer,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface != &Core.Display.info) return error.WrongInterface;
        const action = try handler.runtime.decodeDisplayRequest(peer, message, fds, null);
        const callback = switch (action) {
            .sync => |value| value,
            .get_registry => return error.UnexpectedRequest,
        };
        try handler.runtime.completeSync(peer, callback, 77);
        if (handler.saturate_submission_queue) {
            handler.saturate_submission_queue = false;
            while (true) {
                const submission = handler.runtime.clients.reactor.ring.get_sqe() catch |err| {
                    if (err != error.SubmissionQueueFull) return err;
                    break;
                };
                submission.prep_nop();
                submission.user_data = std.math.maxInt(u64);
                handler.queued_nops += 1;
            }
        }
        return .continue_dispatch;
    }
};

const VisibilityState = struct {
    allowed_slot: u24 = 0,
    restricted_context: u8 = 0,
};

fn globalVisible(context: ?*anyopaque, visibility: wayring.server.GlobalVisibility) bool {
    const state: *VisibilityState = @ptrCast(@alignCast(context.?));
    const restricted: ?*anyopaque = &state.restricted_context;
    return visibility.global_context != restricted or visibility.peer.slot == state.allowed_slot;
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

/// Model check of registry publication and removed-global lifetimes. An
/// abstract model records which registry events each registry is owed and
/// each offer's state. Every transition is replayed on a real runtime with
/// real sockets and small transmit budgets; each queued event is decoded and
/// must be owed, binds and acks must match offer state, withdrawal must happen
/// exactly when the last offer ends, and draining from every state must deliver
/// everything owed and reclaim every removed global.
const RegistryModelCheck = struct {
    const Runtime = wayring.server.Runtime(protocol);
    const Peer = wayring.io_uring.Peer;
    const global_count = 2;
    const registry_count = 3;
    const peer_count = 2;
    const registry_peer = [registry_count]u1{ 0, 0, 1 };
    const registry_id = [registry_count]u32{ 2, 3, 2 };
    const callback_id = 10;
    const callback_data = 7;
    const bind_id = 8;
    const byte_budget = 96;
    const delete_id_size = 12;

    const Op = union(enum) {
        publish,
        /// Every client reads and publication runs until complete.
        settle,
        drain: u1,
        add_global: u1,
        remove_global: u1,
        create_registry: u2,
        remove_registry: u2,
        ack: struct { registry: u2, global: u1 },
        bind: struct { peer: u1, global: u1 },
        sync: u1,
        destroy_client: u1,
    };

    const ops = blk: {
        var list: []const Op = &.{ .publish, .settle };
        for (0..peer_count) |p| list = list ++ &[_]Op{
            .{ .drain = p },                          .{ .sync = p },                           .{ .destroy_client = p },
            .{ .bind = .{ .peer = p, .global = 0 } }, .{ .bind = .{ .peer = p, .global = 1 } },
        };
        for (0..global_count) |g| list = list ++ &[_]Op{ .{ .add_global = g }, .{ .remove_global = g } };
        for (0..registry_count) |r| {
            list = list ++ &[_]Op{ .{ .create_registry = r }, .{ .remove_registry = r } };
            for (0..global_count) |g| list = list ++ &[_]Op{.{ .ack = .{ .registry = r, .global = g } }};
        }
        break :blk list;
    };

    const Life = enum(u2) { unborn, live, gone };
    const Offer = enum(u2) { none, offered, removal_sent };

    const Model = struct {
        globals: [global_count]Life = @splat(.unborn),
        registries: [registry_count]Life = @splat(.unborn),
        peers_live: [peer_count]bool = @splat(true),
        offer: [registry_count][global_count]Offer = @splat(@splat(.none)),
        owed_add: [registry_count][global_count]bool = @splat(@splat(false)),
        owed_remove: [registry_count][global_count]bool = @splat(@splat(false)),
        sync_pending: [peer_count]bool = @splat(false),
        /// Events owed to the peer's registries when its sync was requested.
        sync_owed: [peer_count]u16 = @splat(0),
        /// publishNext reported complete and no mutation has happened since.
        clean: bool = true,
        queued: [peer_count]u8 = @splat(0),

        fn owedBit(r: usize, g: usize, remove: bool) u16 {
            return @as(u16, 1) << @intCast((r * global_count + g) * 2 + @intFromBool(remove));
        }

        fn owedMask(model: Model, p: usize) u16 {
            var mask: u16 = 0;
            for (0..registry_count) |r| {
                if (registry_peer[r] != p) continue;
                for (0..global_count) |g| {
                    if (model.owed_add[r][g]) mask |= owedBit(r, g, false);
                    if (model.owed_remove[r][g]) mask |= owedBit(r, g, true);
                }
            }
            return mask;
        }

        fn anyOwed(model: Model) bool {
            for (0..peer_count) |p| if (model.owedMask(p) != 0) return true;
            return false;
        }

        fn hasOffer(model: Model, g: usize) bool {
            for (0..registry_count) |r| if (model.offer[r][g] != .none) return true;
            return false;
        }

        fn peerHasOffer(model: Model, p: usize, g: usize) bool {
            for (0..registry_count) |r|
                if (registry_peer[r] == p and model.offer[r][g] != .none) return true;
            return false;
        }

        fn dropRegistry(model: *Model, r: usize) void {
            model.registries[r] = .gone;
            model.offer[r] = @splat(.none);
            model.owed_add[r] = @splat(false);
            model.owed_remove[r] = @splat(false);
        }

        fn key(model: Model) u128 {
            var value: u128 = @intFromBool(model.clean);
            for (model.globals) |life| value = value << 2 | @intFromEnum(life);
            for (model.registries) |life| value = value << 2 | @intFromEnum(life);
            for (model.peers_live, model.sync_pending, model.sync_owed, model.queued) |live, pending, owed, queued| {
                value = value << 1 | @intFromBool(live);
                value = value << 1 | @intFromBool(pending);
                value = value << 12 | owed;
                value = value << 7 | queued;
            }
            for (0..registry_count) |r| for (0..global_count) |g| {
                value = value << 2 | @intFromEnum(model.offer[r][g]);
                value = value << 1 | @intFromBool(model.owed_add[r][g]);
                value = value << 1 | @intFromBool(model.owed_remove[r][g]);
            };
            return value;
        }
    };

    const World = struct {
        reactor: *wayring.io_uring.Reactor,
        runtime: Runtime,
        listener_remote: linux.fd_t,
        peers: [peer_count]Peer,
        remotes: [peer_count]linux.fd_t,
        registries: [registry_count]wayring.objects.Handle = undefined,
        globals: [global_count]wayring.objects.Handle = undefined,
        states: [global_count]WithdrawalState = @splat(.{}),
        parsed: [peer_count]usize = @splat(0),
        model: Model = .{},
        last_publish: ?std.meta.Tag(Runtime.PublishResult) = null,
        message_bytes: [256]u8 = undefined,

        /// The reactor is shared across replays; each world gets a fresh
        /// runtime, so global names and object state restart from scratch.
        fn init(world: *World, reactor: *wayring.io_uring.Reactor) !void {
            const allocator = std.testing.allocator;
            world.* = .{
                .reactor = reactor,
                .runtime = undefined,
                .listener_remote = undefined,
                .peers = undefined,
                .remotes = undefined,
            };
            var listener: [2]linux.fd_t = undefined;
            try expectSocketPair(&listener);
            world.listener_remote = listener[1];
            world.runtime = try Runtime.init(allocator, world.reactor, listener[0], .{
                .actor = .{ .received_fd_budget = 1, .transmit_byte_budget = byte_budget, .transmit_fd_budget = 1 },
                .object_capacity = 16,
                .object_quota = 16,
                .buckets_per_client = 16,
                .max_globals = global_count,
                .registry_capacity = registry_count,
            });
            for (&world.peers, &world.remotes) |*peer, *remote| {
                var sockets: [2]linux.fd_t = undefined;
                try expectSocketPair(&sockets);
                peer.* = try world.runtime.clients.admit(.{ .fd = sockets[0], .more = true }, world.runtime.actor_config, null);
                remote.* = sockets[1];
            }
            // Recycled slots come back in LIFO order; publication iterates by
            // slot, so keep peer indexes in slot order for deterministic replay.
            if (world.peers[0].slot > world.peers[1].slot) {
                std.mem.swap(Peer, &world.peers[0], &world.peers[1]);
                std.mem.swap(linux.fd_t, &world.remotes[0], &world.remotes[1]);
            }
            _ = try world.reactor.ring.submit();
        }

        fn peerIndex(world: *World, peer: Peer) !usize {
            for (world.peers, 0..) |candidate, p| {
                if (world.model.peers_live[p] and std.meta.eql(candidate, peer)) return p;
            }
            return error.UnknownPeer;
        }

        fn transmit(world: *World, p: usize) !*wayring.tx.Queue {
            return &(try world.reactor.getActor(world.peers[p])).transmit;
        }

        /// Decodes messages queued on peer `p` since the previous call.
        fn newMessages(world: *World, p: usize, out: *[4]wayring.wire.Message) ![]wayring.wire.Message {
            if (!world.model.peers_live[p]) return out[0..0];
            const queue = try world.transmit(p);
            const total = queue.queuedBytes();
            if (total == world.parsed[p]) return out[0..0];
            var descriptor_scratch: [1]linux.fd_t = undefined;
            var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
            const snapshot = try queue.snapshot(&descriptor_scratch, &control);
            try std.testing.expectEqual(total, snapshot.byteCount());
            @memcpy(world.message_bytes[0..snapshot.first.len], snapshot.first);
            @memcpy(world.message_bytes[snapshot.first.len..total], snapshot.second);
            var offset = world.parsed[p];
            var count: usize = 0;
            while (offset < total) : (count += 1) {
                const message = (try wayring.wire.Message.decode(world.message_bytes[offset..total])) orelse
                    return error.IncompleteMessage;
                out[count] = message;
                offset += message.header.size;
            }
            world.parsed[p] = total;
            world.model.queued[p] = @intCast(total);
            return out[0..count];
        }

        fn expectNoNewMessages(world: *World) !void {
            for (0..peer_count) |p| {
                if (!world.model.peers_live[p]) continue;
                try std.testing.expectEqual(world.parsed[p], (try world.transmit(p)).queuedBytes());
            }
        }

        fn argument(message: wayring.wire.Message, index: usize) u32 {
            return std.mem.readInt(u32, message.payload[index * 4 ..][0..4], @import("builtin").cpu.arch.endian());
        }

        fn globalIndex(world: *World, name: u32) !usize {
            for (world.model.globals, world.globals, 0..) |life, handle, g| {
                if (life != .unborn and handle.id == name) return g;
            }
            return error.UnknownGlobalEvent;
        }

        /// Checks one event published to peer `p` against the owed events.
        fn observePublished(world: *World, p: usize) !void {
            const model = &world.model;
            var storage: [4]wayring.wire.Message = undefined;
            const messages = try world.newMessages(p, &storage);
            if (messages.len == 2) {
                // wl_callback.done followed by wl_display.delete_id.
                try std.testing.expectEqual(@as(u32, callback_id), messages[0].header.object_id);
                try std.testing.expectEqual(@as(u16, 0), messages[0].header.opcode);
                try std.testing.expectEqual(@as(u32, callback_data), argument(messages[0], 0));
                try std.testing.expectEqual(@as(u32, 1), messages[1].header.object_id);
                try std.testing.expectEqual(@as(u16, 1), messages[1].header.opcode);
                try std.testing.expectEqual(@as(u32, callback_id), argument(messages[1], 0));
                try std.testing.expect(model.sync_pending[p]);
                // Every registry event owed when the sync arrived precedes done.
                try std.testing.expectEqual(@as(u16, 0), model.sync_owed[p] & model.owedMask(p));
                model.sync_pending[p] = false;
                model.sync_owed[p] = 0;
                return;
            }
            try std.testing.expectEqual(@as(usize, 1), messages.len);
            const message = messages[0];
            const r = for (0..registry_count) |r| {
                if (registry_peer[r] == p and model.registries[r] == .live and
                    registry_id[r] == message.header.object_id) break r;
            } else return error.EventForUnknownRegistry;
            const g = try world.globalIndex(argument(message, 0));
            switch (message.header.opcode) {
                0 => {
                    try std.testing.expectEqual(@as(usize, 32), message.payload.len);
                    try std.testing.expectEqual(@as(u32, 1), argument(message, 7));
                    try std.testing.expect(model.owed_add[r][g]);
                    try std.testing.expectEqual(Offer.none, model.offer[r][g]);
                    model.owed_add[r][g] = false;
                    model.offer[r][g] = .offered;
                },
                1 => {
                    try std.testing.expect(model.owed_remove[r][g]);
                    try std.testing.expectEqual(Offer.offered, model.offer[r][g]);
                    model.owed_remove[r][g] = false;
                    model.offer[r][g] = .removal_sent;
                },
                else => return error.UnexpectedRegistryEvent,
            }
        }

        /// Applies `op` to the model and the runtime, checking the runtime's
        /// outcome. Returns false, with nothing changed, when not applicable.
        fn apply(world: *World, op: Op) !bool {
            const model = &world.model;
            const runtime = &world.runtime;
            switch (op) {
                .publish => {
                    const result = try runtime.publishNext();
                    world.last_publish = result;
                    switch (result) {
                        .complete => {
                            try std.testing.expect(!model.anyOwed());
                            for (0..peer_count) |p|
                                try std.testing.expect(!(model.peers_live[p] and model.sync_pending[p]));
                            model.clean = true;
                        },
                        .blocked => |peer| {
                            const p = try world.peerIndex(peer);
                            try std.testing.expect(model.owedMask(p) != 0 or model.sync_pending[p]);
                        },
                        .sent => |peer| try world.observePublished(try world.peerIndex(peer)),
                    }
                },
                .settle => {
                    if (model.clean and std.mem.allEqual(u8, &model.queued, 0)) return false;
                    var steps: usize = 0;
                    while (true) : (steps += 1) {
                        try std.testing.expect(steps < 64);
                        for (0..peer_count) |p| _ = try world.apply(.{ .drain = @intCast(p) });
                        try std.testing.expect(try world.apply(.publish));
                        try world.check();
                        if (world.last_publish.? == .complete) break;
                    }
                    for (0..peer_count) |p| _ = try world.apply(.{ .drain = @intCast(p) });
                },
                .drain => |p| {
                    if (!model.peers_live[p] or model.queued[p] == 0) return false;
                    try consume(try world.transmit(p));
                    world.parsed[p] = 0;
                    model.queued[p] = 0;
                },
                .add_global => |g| {
                    if (model.globals[g] != .unborn) return false;
                    const result = runtime.addGlobalWithBinder(
                        &protocol.wp_wayring_test_v1.info,
                        1,
                        &world.states[g],
                        WithdrawalState.bind,
                    );
                    world.globals[g] = (try mutationOutcome(model.*, result)) orelse return true;
                    model.globals[g] = .live;
                    for (0..registry_count) |r| {
                        if (model.registries[r] == .live) model.owed_add[r][g] = true;
                    }
                    model.clean = false;
                },
                .remove_global => |g| {
                    if (model.globals[g] != .live) return false;
                    const result = runtime.removeGlobalWithCallback(world.globals[g], WithdrawalState.withdrawn);
                    _ = (try mutationOutcome(model.*, if (result) |_| true else |err| err)) orelse return true;
                    model.globals[g] = .gone;
                    for (0..registry_count) |r| {
                        if (model.offer[r][g] == .offered) model.owed_remove[r][g] = true;
                    }
                    model.clean = false;
                },
                .create_registry => |r| {
                    const p = registry_peer[r];
                    if (model.registries[r] != .unborn or !model.peers_live[p]) return false;
                    world.registries[r] = try createRegistry(runtime, world.peers[p], registry_id[r]);
                    model.registries[r] = .live;
                    for (0..global_count) |g| {
                        if (model.globals[g] != .live) continue;
                        model.owed_add[r][g] = true;
                        model.clean = false;
                    }
                },
                .remove_registry => |r| {
                    const p = registry_peer[r];
                    if (model.registries[r] != .live) return false;
                    const result = runtime.removeRegistry(world.peers[p], world.registries[r]);
                    if (model.queued[p] + delete_id_size > byte_budget) {
                        try std.testing.expectError(error.ByteBudgetExceeded, result);
                        return true;
                    }
                    _ = try result;
                    var storage: [4]wayring.wire.Message = undefined;
                    const messages = try world.newMessages(p, &storage);
                    try std.testing.expectEqual(@as(usize, 1), messages.len);
                    try std.testing.expectEqual(@as(u32, 1), messages[0].header.object_id);
                    try std.testing.expectEqual(@as(u16, 1), messages[0].header.opcode);
                    try std.testing.expectEqual(registry_id[r], argument(messages[0], 0));
                    model.dropRegistry(r);
                },
                .ack => |target| {
                    const r = target.registry;
                    const g = target.global;
                    if (model.registries[r] != .live or model.globals[g] == .unborn) return false;
                    const result = runtime.ackGlobalRemove(world.peers[registry_peer[r]], world.registries[r], world.globals[g].id);
                    if (model.offer[r][g] == .removal_sent) {
                        try result;
                        model.offer[r][g] = .none;
                    } else try std.testing.expectError(error.InvalidAckRemove, result);
                },
                .bind => |target| {
                    const p = target.peer;
                    const g = target.global;
                    if (!model.peers_live[p] or model.globals[g] == .unborn) return false;
                    const binds = world.states[g].binds;
                    const result = runtime.bindGlobal(world.peers[p], .{ .bind = .{
                        .name = world.globals[g].id,
                        .id = .{ .interface = protocol.wp_wayring_test_v1.info.name, .version = 1, .id = bind_id },
                    } });
                    if (model.globals[g] == .live or model.peerHasOffer(p, g)) {
                        const resource = try result;
                        try std.testing.expectEqual(binds + 1, world.states[g].binds);
                        try std.testing.expectEqual(world.globals[g], world.states[g].last.?.global);
                        _ = try (try runtime.clients.get(world.peers[p])).removeClient(resource);
                    } else {
                        try std.testing.expectError(error.UnknownGlobal, result);
                        try std.testing.expectEqual(binds, world.states[g].binds);
                    }
                },
                .sync => |p| {
                    if (!model.peers_live[p] or model.sync_pending[p]) return false;
                    var bytes: [12]u8 = undefined;
                    try (wayring.wire.Header{ .object_id = 1, .opcode = 0, .size = bytes.len }).encode(bytes[0..8]);
                    std.mem.writeInt(u32, bytes[8..], callback_id, @import("builtin").cpu.arch.endian());
                    const action = try runtime.decodeDisplayRequest(
                        world.peers[p],
                        (try wayring.wire.Message.decode(&bytes)).?,
                        &(try world.reactor.getActor(world.peers[p])).received_fds,
                        null,
                    );
                    try runtime.completeSync(world.peers[p], action.sync, callback_data);
                    model.sync_pending[p] = true;
                    model.sync_owed[p] = model.owedMask(p);
                },
                .destroy_client => |p| {
                    if (!model.peers_live[p]) return false;
                    try stopPeers(world.reactor, &.{world.peers[p]});
                    try runtime.destroyClient(world.peers[p]);
                    model.peers_live[p] = false;
                    for (0..registry_count) |r| {
                        if (registry_peer[r] == p and model.registries[r] == .live) model.dropRegistry(r);
                    }
                    model.sync_pending[p] = false;
                    model.sync_owed[p] = 0;
                    model.queued[p] = 0;
                    world.parsed[p] = 0;
                },
            }
            return true;
        }

        /// Global mutations are rejected while any registry event is owed and
        /// accepted after publication reported complete. In between, the
        /// runtime may still hold an exhausted cursor, so either is allowed.
        fn mutationOutcome(model: Model, result: anytype) !?@typeInfo(@TypeOf(result)).error_union.payload {
            if (model.anyOwed()) {
                try std.testing.expectError(error.GlobalUpdateActive, result);
                return null;
            }
            return result catch |err| {
                if (model.clean) return err;
                try std.testing.expectEqual(error.GlobalUpdateActive, err);
                return null;
            };
        }

        fn check(world: *World) !void {
            try world.expectNoNewMessages();
            for (0..peer_count) |p| {
                if (world.model.peers_live[p])
                    try std.testing.expectEqual(@as(usize, world.model.queued[p]), (try world.transmit(p)).queuedBytes());
            }
            // Withdrawal happens exactly once, when a removed global's last offer ends.
            for (world.model.globals, world.states, world.globals, 0..) |life, state, handle, g| {
                const withdrawn = life == .gone and !world.model.hasOffer(g);
                try std.testing.expectEqual(@as(usize, @intFromBool(withdrawn)), state.withdrawals);
                if (withdrawn) try std.testing.expectEqual(handle, state.withdrawn_handle.?);
            }
        }

        /// Liveness: when every client reads, publication delivers every owed
        /// event and sync; destroying the clients then withdraws every removed
        /// global and lets the runtime shut down.
        fn teardown(world: *World) !void {
            _ = try world.apply(.settle);
            try std.testing.expect(world.model.clean);
            for (0..peer_count) |p| _ = try world.apply(.{ .destroy_client = @intCast(p) });
            try world.check();
            for (world.model.globals, world.states) |life, state|
                try std.testing.expectEqual(@as(usize, @intFromBool(life == .gone)), state.withdrawals);
            try world.runtime.deinit(std.testing.allocator);
            for (world.remotes) |remote| _ = linux.close(remote);
            _ = linux.close(world.listener_remote);
        }
    };

    const Node = struct { parent: u32, op: Op, depth: u8 };

    /// Breadth-first exploration to `max_depth` operations; returns the
    /// number of distinct abstract states reached.
    fn explore(max_depth: u8) !usize {
        const allocator = std.testing.allocator;
        var reactor: wayring.io_uring.Reactor = undefined;
        try reactor.initOwned(allocator, .{ .entries = 16 }, .{
            .receive_buffer_size = 4096,
            .receive_buffer_count = 4,
            .receive_control_capacity = 64,
            .fragment_block_size = 64,
            .fragment_block_count = 2,
            .transmit_block_size = 256,
            .transmit_block_count = 4,
            .descriptor_count = 4,
            .send_descriptor_capacity = 1,
        });
        // Released only on success: a failed check leaves live peers behind,
        // and the reactor's teardown assertion would mask the real failure.
        var nodes: std.ArrayList(Node) = .empty;
        defer nodes.deinit(allocator);
        var seen: std.AutoHashMapUnmanaged(u128, void) = .empty;
        defer seen.deinit(allocator);
        try nodes.append(allocator, .{ .parent = std.math.maxInt(u32), .op = undefined, .depth = 0 });
        try seen.put(allocator, (Model{}).key(), {});

        var path: [32]Op = undefined;
        var current: usize = 0;
        while (current < nodes.items.len) : (current += 1) {
            const depth = nodes.items[current].depth;
            if (depth == max_depth) continue;
            var cursor: u32 = @intCast(current);
            var index: usize = depth;
            while (cursor != 0) : (cursor = nodes.items[cursor].parent) {
                index -= 1;
                path[index] = nodes.items[cursor].op;
            }
            var world: World = undefined;
            var replayed = false;
            for (ops) |op| {
                if (!replayed) {
                    try world.init(&reactor);
                    for (path[0..depth]) |step| try std.testing.expect(try world.apply(step));
                    replayed = true;
                }
                if (!try world.apply(op)) continue;
                replayed = false;
                try world.check();
                const key = world.model.key();
                try world.teardown();
                if (seen.contains(key)) continue;
                try seen.put(allocator, key, {});
                try nodes.append(allocator, .{ .parent = @intCast(current), .op = op, .depth = depth + 1 });
            }
            if (replayed) try world.teardown();
        }
        reactor.deinit(allocator);
        return nodes.items.len;
    }
};

test "registry publication and removed-global lifetimes match a bounded model" {
    // Six operations reach a removal acknowledged after global_remove, plus
    // racing binds, backpressure, and every withdrawal path.
    try std.testing.expect(try RegistryModelCheck.explore(6) > 4000);
}
