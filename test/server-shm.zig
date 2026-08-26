const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("generated_protocol");

const linux = std.os.linux;
const Core = wayring.server.Core(protocol);
const Shm = wayring.server.Shm(protocol);

const formats = [_]wayring.shm.Format{
    .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

test "SHM service validates mandatory formats" {
    try std.testing.expectError(error.InvalidConfig, Shm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = formats[0..1],
    }));

    var service = try Shm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &formats,
    });
    service.deinit(std.testing.allocator);
}

test "SHM service installs a format-advertising global" {
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 8 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = 1,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 2,
        .descriptor_count = 2,
        .send_descriptor_capacity = 1,
    });
    const listener_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (linux.errno(listener_result) != .SUCCESS) return error.SystemCallFailed;
    var runtime = try wayring.server.Runtime(protocol).init(
        std.testing.allocator,
        &reactor,
        @intCast(listener_result),
        .{
            .actor = .{
                .received_fd_budget = 1,
                .transmit_byte_budget = 128,
                .transmit_fd_budget = 1,
            },
            .object_capacity = 1,
            .object_quota = 1,
            .buckets_per_client = 2,
            .max_globals = 1,
            .registry_capacity = 1,
        },
    );
    var service = try Shm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &formats,
    });
    const global = try service.install(&runtime);
    try std.testing.expectEqualStrings(
        protocol.wl_shm.info.name,
        (try runtime.globals.get(global.id)).interface.name,
    );
    try runtime.deinit(std.testing.allocator);
    service.deinit(std.testing.allocator);
    reactor.deinit(std.testing.allocator);
}

test "SHM service owns pool and buffer protocol lifetimes" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer descriptors.deinit(std.testing.allocator);
    var request_queue = wayring.tx.Queue.init(&blocks, 512, &descriptors, 1);
    defer request_queue.deinit();
    var fragment_storage: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(
        0,
        1,
        &fragment_storage,
        &descriptors,
        1,
        &blocks,
        256,
        0,
    );
    defer actor.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        1,
        &Core.Display.info,
        null,
    );
    var service = try Shm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &formats,
    });
    defer {
        server_objects.deinit(std.testing.allocator);
        service.deinit(std.testing.allocator);
    }
    server_objects.setRemovalHook(.{
        .context = &service,
        .notify = removeShmResource,
    });
    const shm_resource = try server_objects.insertClient(
        2,
        &protocol.wl_shm.info,
        2,
        &service,
    );
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 1);
    defer received_fds.deinit();

    const fd = try memfd(4096);
    try protocol.wl_shm.encodeRequest(&request_queue, shm_resource.id, .{
        .create_pool = .{ .id = 3, .fd = fd, .size = 4096 },
    });
    try dispatchRequest(
        &service,
        &actor,
        &server_objects,
        &request_queue,
        &received_fds,
        true,
    );
    const pool = server_objects.namespace.lookupHandle(3) orelse
        return error.MissingPool;

    try protocol.wl_shm_pool.encodeRequest(&request_queue, pool.id, .{
        .create_buffer = .{
            .id = 4,
            .offset = 0,
            .width = 2,
            .height = 2,
            .stride = 8,
            .format = .argb8888,
        },
    });
    try dispatchRequest(
        &service,
        &actor,
        &server_objects,
        &request_queue,
        &received_fds,
        false,
    );
    const buffer = server_objects.namespace.lookupHandle(4) orelse
        return error.MissingBuffer;
    const buffer_object = server_objects.namespace.resolve(buffer) orelse
        return error.MissingBuffer;
    const token = service.bufferToken(buffer_object) orelse
        return error.MissingBufferToken;
    try std.testing.expectEqual(@as(u32, 2), (try service.store.bufferInfo(token)).width);

    try protocol.wl_shm_pool.encodeRequest(&request_queue, pool.id, .{ .destroy = .{} });
    try dispatchRequest(
        &service,
        &actor,
        &server_objects,
        &request_queue,
        &received_fds,
        false,
    );
    try std.testing.expect(server_objects.namespace.resolve(pool) == null);
    try std.testing.expectEqual(@as(u32, 2), (try service.store.bufferInfo(token)).width);

    try protocol.wl_buffer.encodeRequest(&request_queue, buffer.id, .{ .destroy = .{} });
    try dispatchRequest(
        &service,
        &actor,
        &server_objects,
        &request_queue,
        &received_fds,
        false,
    );
    try std.testing.expect(server_objects.namespace.resolve(buffer) == null);
    try std.testing.expectError(error.StaleBuffer, service.store.bufferInfo(token));

    const disconnect_fd = try memfd(4096);
    try protocol.wl_shm.encodeRequest(&request_queue, shm_resource.id, .{
        .create_pool = .{ .id = 5, .fd = disconnect_fd, .size = 4096 },
    });
    try dispatchRequest(
        &service,
        &actor,
        &server_objects,
        &request_queue,
        &received_fds,
        true,
    );
    const disconnect_pool = server_objects.namespace.lookupHandle(5) orelse
        return error.MissingPool;
    try protocol.wl_shm_pool.encodeRequest(&request_queue, disconnect_pool.id, .{
        .create_buffer = .{
            .id = 6,
            .offset = 0,
            .width = 2,
            .height = 2,
            .stride = 8,
            .format = .xrgb8888,
        },
    });
    try dispatchRequest(
        &service,
        &actor,
        &server_objects,
        &request_queue,
        &received_fds,
        false,
    );
    try protocol.wl_shm_pool.encodeRequest(&request_queue, disconnect_pool.id, .{
        .create_buffer = .{
            .id = 7,
            .offset = 0,
            .width = 2,
            .height = 2,
            .stride = 8,
            .format = protocol.wl_shm.format.fromInt(99),
        },
    });
    try std.testing.expectEqual(
        wayring.dispatch.Control.stop,
        try dispatchRequestControl(
            &service,
            &actor,
            &server_objects,
            &request_queue,
            &received_fds,
            false,
        ),
    );
    try std.testing.expectEqual(wayring.connection.Lifecycle.draining, actor.lifecycle);
    try std.testing.expect(server_objects.namespace.get(7) == null);
}

fn removeShmResource(
    context: ?*anyopaque,
    handle: wayring.objects.Handle,
    object: wayring.objects.Object,
) void {
    const service: *Shm = @ptrCast(@alignCast(context.?));
    _ = service.resourceRemoved(handle, object);
}

fn dispatchRequest(
    service: *Shm,
    actor: *wayring.connection.Actor,
    server_objects: *wayring.objects.ServerObjects,
    queue: *wayring.tx.Queue,
    received_fds: *wayring.ancillary.FdQueue,
    duplicate_fd: bool,
) !void {
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        try dispatchRequestControl(
            service,
            actor,
            server_objects,
            queue,
            received_fds,
            duplicate_fd,
        ),
    );
}

fn dispatchRequestControl(
    service: *Shm,
    actor: *wayring.connection.Actor,
    server_objects: *wayring.objects.ServerObjects,
    queue: *wayring.tx.Queue,
    received_fds: *wayring.ancillary.FdQueue,
    duplicate_fd: bool,
) !wayring.dispatch.Control {
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)) orelse
        return error.IncompleteMessage;
    if (duplicate_fd) {
        const duplicate_result = linux.dup(descriptor_scratch[0]);
        if (linux.errno(duplicate_result) != .SUCCESS) return error.SystemCallFailed;
        try received_fds.append(@intCast(duplicate_result));
    }
    const target = try server_objects.namespace.request(
        message.header.object_id,
        message.header.opcode,
    );
    const control_result = (try service.request(
        actor,
        server_objects,
        target,
        message,
        received_fds,
    )).?;
    try queue.begin(snapshot);
    try queue.complete(snapshot.byteCount());
    return control_result;
}

fn memfd(size: usize) !linux.fd_t {
    const result = linux.memfd_create("wayring-server-shm-test", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS)
        return error.SystemCallFailed;
    return fd;
}
