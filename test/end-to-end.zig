const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("generated_protocol");

const linux = std.os.linux;
const ClientCore = wayring.client.Core(protocol);
const ServerCore = wayring.server.Core(protocol);
const ClientConnection = wayring.client.Connection(protocol);
const ServerConnections = wayring.server.SharedClients(protocol);

test "client and server complete a core round trip on one reactor" {
    var sockets: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &sockets,
    )));

    var ring = try linux.IoUring.init(
        16,
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN,
    );
    defer ring.deinit();
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initBorrowed(std.testing.allocator, &ring, .{
        .max_connections = 2,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 4,
        .receive_control_capacity = 256,
        .fragment_block_size = 64,
        .fragment_block_count = 2,
        .transmit_block_size = 64,
        .transmit_block_count = 4,
        .descriptor_count = 4,
        .send_descriptor_capacity = 1,
    });
    const actor_config: wayring.io_uring.ActorConfig = .{
        .received_fd_budget = 1,
        .transmit_byte_budget = 128,
        .transmit_fd_budget = 1,
    };
    var server_connections = try ServerConnections.init(
        std.testing.allocator,
        &reactor,
        4,
        4,
        8,
    );
    const server_peer = try server_connections.admit(
        .{ .fd = sockets[0], .more = false },
        actor_config,
        null,
    );
    var client_connection = try ClientConnection.attach(
        std.testing.allocator,
        &reactor,
        sockets[1],
        actor_config,
        .{ .max_objects = 4, .max_client_ids = 3 },
    );
    const client_peer = client_connection.peer;
    const server_objects = try server_connections.get(server_peer);

    const client_actor = try client_connection.actor();
    const callback = try ClientCore.sync(
        &client_connection.objects,
        &client_actor.transmit,
        null,
    );
    try reactor.prepareSend(client_peer);
    const nop_tag: u64 = 0xffff_ffff_ffff_ff00;
    _ = try ring.nop(nop_tag);
    _ = try reactor.ring.submit();

    var server_handler: ServerHandler = .{
        .objects = server_objects,
        .queue = &(try reactor.getActor(server_peer)).transmit,
    };
    var client_handler: ClientHandler = .{
        .objects = &client_connection.objects,
        .callback = callback,
    };
    var nop_seen = false;

    while (!client_handler.done or !client_handler.deleted) {
        const completion = try reactor.ring.copy_cqe();
        if (completion.user_data == nop_tag) {
            nop_seen = true;
            continue;
        }
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const peer = reactor.routedPeer(routed);
        const actor = try reactor.getActor(peer);
        const event = try actor.completeRouted(routed.operation, completion);
        var prepared = false;
        switch (event) {
            .received => {
                const receiver = try reactor.getReceiver(peer);
                if (peer.slot == server_peer.slot) {
                    switch (try ServerCore.receivedRequests(
                        actor,
                        &server_objects.namespace,
                        receiver,
                        completion,
                        &server_handler,
                    )) {
                        .dispatched => {},
                        .terminal => |failure| return failure.cause,
                    }
                } else {
                    switch (try ClientCore.receivedEvents(
                        actor,
                        &client_connection.objects.namespace,
                        receiver,
                        completion,
                        &client_handler,
                    )) {
                        .dispatched => {},
                        .terminal => |failure| return failure.cause,
                    }
                }
                if (!actor.receive_active) {
                    try reactor.prepareReceive(peer);
                    prepared = true;
                }
            },
            .sent => |sent| if (sent.more_queued) {
                try reactor.prepareSend(peer);
                prepared = true;
            },
            .buffers_exhausted => {
                try reactor.prepareReceive(peer);
                prepared = true;
            },
            else => return error.InvalidCompletion,
        }
        if (actor.transmit.queuedBytes() > 0 and !actor.transmit.sendActive()) {
            try reactor.prepareSend(peer);
            prepared = true;
        }
        if (prepared) _ = try reactor.ring.submit();
    }

    try std.testing.expect(nop_seen);
    try std.testing.expectEqual(@as(u32, 91), client_handler.callback_data);
    try std.testing.expect(client_connection.objects.namespace.resolve(callback) == null);
    try std.testing.expect(!client_connection.objects.ids.isActive(callback.id));
    try std.testing.expectEqual(@as(usize, 1), server_objects.namespace.count);

    _ = try server_connections.prepareClose(server_peer);
    _ = try client_connection.prepareClose();
    _ = try reactor.ring.submit();
    while (!(try reactor.getActor(server_peer)).canDeinit() or
        !(try reactor.getActor(client_peer)).canDeinit())
    {
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const peer = reactor.routedPeer(routed);
        const actor = try reactor.getActor(peer);
        const event = try actor.completeRouted(routed.operation, completion);
        switch (event) {
            .received => try (try reactor.getReceiver(peer)).buffers.put(completion),
            .receive_stopped, .buffers_exhausted, .cancel_complete, .disconnected => {},
            else => return error.InvalidCompletion,
        }
    }
    try server_connections.destroy(server_peer);
    try client_connection.deinit(std.testing.allocator);
    server_connections.deinit(std.testing.allocator);
    reactor.deinit(std.testing.allocator);

    const final_nop: u64 = 0x1234_5600;
    _ = try ring.nop(final_nop);
    _ = try ring.submit_and_wait(1);
    try std.testing.expectEqual(final_nop, (try ring.copy_cqe()).user_data);
}

test "client connection rolls back failed object initialization" {
    var sockets: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &sockets,
    )));
    defer _ = linux.close(sockets[1]);
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 8 }, .{
        .max_connections = 1,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 1,
        .descriptor_count = 2,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidConfig, ClientConnection.attach(
        std.testing.allocator,
        &reactor,
        sockets[0],
        .{
            .received_fd_budget = 1,
            .transmit_byte_budget = 64,
            .transmit_fd_budget = 1,
        },
        .{ .max_objects = 0, .max_client_ids = 1 },
    ));
    try std.testing.expectEqual(@as(usize, 0), reactor.slots.active_count);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(sockets[0], linux.F.GETFD, 0)),
    );
}

const ServerHandler = struct {
    objects: *wayring.objects.SharedServerObjects,
    queue: *wayring.tx.Queue,

    pub fn request(
        handler: *ServerHandler,
        _: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const action = try ServerCore.decodeDisplayRequest(
            handler.objects,
            message,
            fds,
            null,
        );
        const callback = switch (action) {
            .sync => |value| value,
            else => return error.UnexpectedRequest,
        };
        try ServerCore.completeSync(handler.objects, handler.queue, callback, 91);
        return .continue_dispatch;
    }
};

const ClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    callback: wayring.objects.Handle,
    callback_data: u32 = 0,
    done: bool = false,
    deleted: bool = false,

    pub fn event(
        handler: *ClientHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Callback.info) {
            const event_value = try ClientCore.decodeCallbackEvent(
                handler.objects,
                handler.callback,
                message,
                fds,
            );
            handler.callback_data = switch (event_value) {
                .done => |value| value.callback_data,
            };
            handler.done = true;
        } else if (target.object.interface == &ClientCore.Display.info) {
            const event_value = try ClientCore.decodeDisplayEvent(
                handler.objects,
                message,
                fds,
            );
            switch (event_value) {
                .delete_id => |value| {
                    if (value.id != handler.callback.id) return error.UnexpectedObject;
                    handler.deleted = true;
                },
                .@"error" => return error.ProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};
