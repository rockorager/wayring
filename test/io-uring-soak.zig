const std = @import("std");
const wayring = @import("wayring");
const options = @import("soak_options");

const linux = std.os.linux;
const max_connections = 8;
const max_payload = 512;

const State = struct {
    peer: wayring.io_uring.Peer,
    remote: linux.fd_t,
    inbound: [max_payload]u8,
    inbound_len: usize,
    inbound_received: usize = 0,
    inbound_fd: bool,
    inbound_fds_received: usize = 0,
    outbound: [max_payload]u8,
    outbound_len: usize,
    outbound_fd: bool,
};

test "randomized real io_uring connection soak" {
    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 64 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = 16,
        .receive_control_capacity = 256,
        .fragment_block_size = 1024,
        .fragment_block_count = max_connections,
        .transmit_block_size = 64,
        .transmit_block_count = 80,
        .descriptor_count = 32,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(std.testing.allocator);
    const actor_config: wayring.io_uring.ActorConfig = .{
        .received_fd_budget = 1,
        .transmit_byte_budget = max_payload,
        .transmit_fd_budget = 1,
    };
    var prior_generations = [_]u32{0} ** max_connections;

    for (0..options.rounds) |_| {
        const count = random.intRangeAtMost(usize, 1, max_connections);
        var states: [max_connections]State = undefined;
        for (states[0..count]) |*state| {
            var sockets: [2]linux.fd_t = undefined;
            try expectSuccess(linux.socketpair(
                linux.AF.UNIX,
                linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
                0,
                &sockets,
            ));
            const peer = try reactor.attachReceiving(sockets[0], actor_config);
            if (prior_generations[peer.slot] != 0)
                try std.testing.expect(peer.generation != prior_generations[peer.slot]);
            prior_generations[peer.slot] = peer.generation;
            state.* = .{
                .peer = peer,
                .remote = sockets[1],
                .inbound = undefined,
                .inbound_len = random.intRangeAtMost(usize, 1, max_payload),
                .inbound_fd = random.boolean(),
                .outbound = undefined,
                .outbound_len = random.intRangeAtMost(usize, 1, max_payload),
                .outbound_fd = random.boolean(),
            };
            random.bytes(state.inbound[0..state.inbound_len]);
            random.bytes(state.outbound[0..state.outbound_len]);

            var input_offset: usize = 0;
            var first_chunk = true;
            while (input_offset < state.inbound_len) {
                const chunk_len = random.intRangeAtMost(
                    usize,
                    1,
                    @min(state.inbound_len - input_offset, 73),
                );
                if (first_chunk and state.inbound_fd) {
                    const descriptor = try createDescriptor();
                    try sendWithDescriptor(
                        state.remote,
                        state.inbound[input_offset..][0..chunk_len],
                        descriptor,
                    );
                    _ = linux.close(descriptor);
                } else try writeAll(
                    state.remote,
                    state.inbound[input_offset..][0..chunk_len],
                );
                first_chunk = false;
                input_offset += chunk_len;
            }

            const actor = try reactor.getActor(peer);
            var output_offset: usize = 0;
            first_chunk = true;
            while (output_offset < state.outbound_len) {
                const chunk_len = random.intRangeAtMost(
                    usize,
                    1,
                    @min(state.outbound_len - output_offset, 79),
                );
                if (first_chunk and state.outbound_fd) {
                    const descriptor = try createDescriptor();
                    try actor.enqueue(
                        state.outbound[output_offset..][0..chunk_len],
                        &.{descriptor},
                    );
                } else try actor.enqueue(
                    state.outbound[output_offset..][0..chunk_len],
                    &.{},
                );
                first_chunk = false;
                output_offset += chunk_len;
            }
            try reactor.prepareSend(peer);
        }
        _ = try reactor.ring.submit();

        var completions: usize = 0;
        while (!trafficComplete(&reactor, states[0..count])) {
            completions += 1;
            if (completions > 10_000) return error.CompletionLimitExceeded;
            const completion = try reactor.ring.copy_cqe();
            const routed = (reactor.route(null, completion) orelse
                return error.InvalidCompletion).connection;
            const peer = reactor.routedPeer(routed);
            const state = findState(states[0..count], peer) orelse
                return error.UnknownPeer;
            const actor = try reactor.getActor(peer);
            const event = try actor.completeRouted(routed.operation, completion);
            var prepared = false;
            switch (event) {
                .received => {
                    const receiver = try reactor.getReceiver(peer);
                    const received = try receiver.decodeCompletion(completion);
                    defer receiver.release(received) catch {};
                    _ = try actor.ingestControl(received.control);
                    const end = state.inbound_received + received.payload.len;
                    if (end > state.inbound_len) return error.ExcessPayload;
                    try std.testing.expectEqualSlices(
                        u8,
                        state.inbound[state.inbound_received..end],
                        received.payload,
                    );
                    state.inbound_received = end;
                    while (actor.takeFd()) |fd| {
                        try expectCloseOnExec(fd);
                        _ = linux.close(fd);
                        state.inbound_fds_received += 1;
                    } else |err| if (err != error.Empty) return err;
                    if (!actor.receive_active and state.inbound_received < state.inbound_len) {
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
                else => return error.UnexpectedCompletion,
            }
            if (prepared) _ = try reactor.ring.submit();
        }

        for (states[0..count]) |*state| {
            try std.testing.expectEqual(
                @as(usize, if (state.inbound_fd) 1 else 0),
                state.inbound_fds_received,
            );
            try receiveRemote(state);
        }

        var order: [max_connections]usize = undefined;
        for (order[0..count], 0..) |*index, value| index.* = value;
        random.shuffle(usize, order[0..count]);
        for (order[0..count]) |index| _ = try reactor.prepareClose(states[index].peer);
        _ = try reactor.ring.submit();
        try finishClosing(&reactor, states[0..count]);
        random.shuffle(usize, order[0..count]);
        for (order[0..count]) |index| {
            const peer = states[index].peer;
            try reactor.destroyPeer(peer);
            try std.testing.expectError(error.SlotInactive, reactor.getActor(peer));
            _ = linux.close(states[index].remote);
        }
        try std.testing.expectEqual(@as(usize, 0), reactor.slots.active_count);
        try std.testing.expectEqual(@as(usize, max_connections), reactor.fragment_blocks.available());
        try std.testing.expectEqual(@as(usize, 80), reactor.transmit_blocks.available());
        try std.testing.expectEqual(@as(usize, 32), reactor.descriptors.available());
    }
}

fn trafficComplete(
    reactor: *wayring.io_uring.Reactor,
    states: []State,
) bool {
    for (states) |state| {
        if (state.inbound_received != state.inbound_len) return false;
        const actor = reactor.getActor(state.peer) catch return false;
        if (actor.transmit.queuedBytes() != 0 or actor.transmit.sendActive()) return false;
    }
    return true;
}

fn findState(states: []State, peer: wayring.io_uring.Peer) ?*State {
    for (states) |*state| {
        if (state.peer.slot == peer.slot and state.peer.generation == peer.generation)
            return state;
    }
    return null;
}

fn receiveRemote(state: *State) !void {
    var pool = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var queue = wayring.ancillary.FdQueue.init(&pool, 1);
    defer queue.deinit();
    var actual: [max_payload]u8 = undefined;
    var offset: usize = 0;
    while (offset < state.outbound_len) {
        var iov: std.posix.iovec = .{
            .base = actual[offset..].ptr,
            .len = state.outbound_len - offset,
        };
        var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var message: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iov),
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const received = try syscallLength(linux.recvmsg(
            state.remote,
            &message,
            linux.MSG.CMSG_CLOEXEC,
        ));
        if (received == 0) return error.UnexpectedEof;
        if (message.flags & (linux.MSG.TRUNC | linux.MSG.CTRUNC) != 0)
            return error.TruncatedMessage;
        _ = try wayring.ancillary.enqueueRights(control[0..message.controllen], &queue);
        offset += received;
    }
    try std.testing.expectEqualSlices(u8, state.outbound[0..state.outbound_len], actual[0..offset]);
    try std.testing.expectEqual(@as(usize, if (state.outbound_fd) 1 else 0), queue.len());
    while (queue.pop()) |fd| {
        try expectCloseOnExec(fd);
        _ = linux.close(fd);
    } else |err| if (err != error.Empty) return err;
}

fn finishClosing(reactor: *wayring.io_uring.Reactor, states: []State) !void {
    var completions: usize = 0;
    while (true) {
        var ready = true;
        for (states) |state| {
            if (!(try reactor.getActor(state.peer)).canDeinit()) {
                ready = false;
                break;
            }
        }
        if (ready) return;
        completions += 1;
        if (completions > 10_000) return error.CompletionLimitExceeded;
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const peer = reactor.routedPeer(routed);
        _ = findState(states, peer) orelse return error.UnknownPeer;
        const actor = try reactor.getActor(peer);
        const event = try actor.completeRouted(routed.operation, completion);
        switch (event) {
            .received => {
                const receiver = try reactor.getReceiver(peer);
                const received = try receiver.decodeCompletion(completion);
                try receiver.release(received);
            },
            .receive_stopped, .cancel_complete, .disconnected, .buffers_exhausted => {},
            else => return error.UnexpectedCompletion,
        }
    }
}

fn sendWithDescriptor(fd: linux.fd_t, bytes: []const u8, descriptor: linux.fd_t) !void {
    var iov: std.posix.iovec_const = .{ .base = bytes.ptr, .len = bytes.len };
    var control_storage: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const control = try wayring.ancillary.encodeRights(&control_storage, &.{descriptor});
    const message: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = control.ptr,
        .controllen = control.len,
        .flags = 0,
    };
    try std.testing.expectEqual(bytes.len, try syscallLength(linux.sendmsg(fd, &message, 0)));
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = try syscallLength(linux.write(fd, bytes[offset..].ptr, bytes.len - offset));
        if (written == 0) return error.UnexpectedEof;
        offset += written;
    }
}

fn createDescriptor() !linux.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try expectSuccess(result);
    return @intCast(result);
}

fn expectCloseOnExec(fd: linux.fd_t) !void {
    const flags = linux.fcntl(fd, linux.F.GETFD, 0);
    try expectSuccess(flags);
    try std.testing.expect(flags & linux.FD_CLOEXEC != 0);
}

fn syscallLength(result: usize) !usize {
    try expectSuccess(result);
    return result;
}

fn expectSuccess(result: usize) !void {
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
}

const backpressure_connections = 4;
const backpressure_block_size = 64 * 1024;
const backpressure_bytes = 4 * backpressure_block_size;

const BackpressureState = struct {
    peer: wayring.io_uring.Peer,
    remote: linux.fd_t,
    pattern: u8,
    in_flight: usize = 0,
    sent: usize = 0,
    received: usize = 0,
    received_fds: usize = 0,
};

test "real io_uring sends resume after forced kernel backpressure" {
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 32 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = backpressure_block_size,
        .transmit_block_count = backpressure_connections * 4,
        .descriptor_count = backpressure_connections,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(std.testing.allocator);
    const actor_config: wayring.io_uring.ActorConfig = .{
        .received_fd_budget = 0,
        .transmit_byte_budget = backpressure_bytes,
        .transmit_fd_budget = 1,
    };
    var states: [backpressure_connections]BackpressureState = undefined;
    var payload: [backpressure_block_size]u8 = undefined;

    for (&states, 0..) |*state, index| {
        var sockets: [2]linux.fd_t = undefined;
        try expectSuccess(linux.socketpair(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            0,
            &sockets,
        ));
        try setSendBuffer(sockets[0], 4096);
        state.* = .{
            .peer = try reactor.attach(sockets[0], actor_config),
            .remote = sockets[1],
            .pattern = @intCast(index + 1),
        };
        @memset(&payload, state.pattern);
        const actor = try reactor.getActor(state.peer);
        const descriptor = try createDescriptor();
        try actor.enqueue(&payload, &.{descriptor});
        for (1..4) |_| try actor.enqueue(&payload, &.{});
    }
    try std.testing.expectEqual(@as(usize, 0), reactor.transmit_blocks.available());

    var pressure_sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &pressure_sockets,
    ));
    const pressure_peer = try reactor.attach(pressure_sockets[0], actor_config);
    const pressure_actor = try reactor.getActor(pressure_peer);
    try std.testing.expectError(error.Exhausted, pressure_actor.enqueue("x", &.{}));

    for (&states) |*state| try prepareBackpressureSend(&reactor, state);
    _ = try reactor.ring.submit();
    var received_pool = try wayring.pool.SharedFds.init(
        std.testing.allocator,
        backpressure_connections,
    );
    defer received_pool.deinit(std.testing.allocator);
    var saw_partial = false;

    while (true) {
        var pending: usize = 0;
        for (states) |state| if (state.in_flight != 0) {
            pending += 1;
        };
        if (pending == 0) break;
        while (pending != 0) {
            const completion = try reactor.ring.copy_cqe();
            const routed = (reactor.route(null, completion) orelse
                return error.InvalidCompletion).connection;
            if (routed.operation != .send) return error.UnexpectedCompletion;
            const peer = reactor.routedPeer(routed);
            const state = findBackpressureState(&states, peer) orelse
                return error.UnknownPeer;
            const submitted = state.in_flight;
            const event = try (try reactor.getActor(peer)).completeRouted(.send, completion);
            if (event.sent.length < submitted) saw_partial = true;
            state.sent += event.sent.length;
            state.in_flight = 0;
            pending -= 1;
        }
        for (&states) |*state| try drainBackpressure(state, &received_pool);
        var prepared = false;
        for (&states) |*state| {
            if (state.sent < backpressure_bytes) {
                try prepareBackpressureSend(&reactor, state);
                prepared = true;
            }
        }
        if (prepared) _ = try reactor.ring.submit();
    }

    try std.testing.expect(saw_partial);
    for (&states) |*state| {
        try drainBackpressure(state, &received_pool);
        try std.testing.expectEqual(backpressure_bytes, state.sent);
        try std.testing.expectEqual(backpressure_bytes, state.received);
        try std.testing.expectEqual(@as(usize, 1), state.received_fds);
    }
    try std.testing.expectEqual(
        @as(usize, backpressure_connections * 4),
        reactor.transmit_blocks.available(),
    );
    try pressure_actor.enqueue("recovered", &.{});
    var pressure_state: BackpressureState = .{
        .peer = pressure_peer,
        .remote = pressure_sockets[1],
        .pattern = 0,
    };
    try prepareBackpressureSend(&reactor, &pressure_state);
    _ = try reactor.ring.submit_and_wait(1);
    const pressure_completion = try reactor.ring.copy_cqe();
    const pressure_routed = (reactor.route(null, pressure_completion) orelse
        return error.InvalidCompletion).connection;
    if (pressure_routed.operation != .send) return error.UnexpectedCompletion;
    const completed_pressure_peer = reactor.routedPeer(pressure_routed);
    try std.testing.expectEqual(pressure_peer.slot, completed_pressure_peer.slot);
    try std.testing.expectEqual(pressure_peer.generation, completed_pressure_peer.generation);
    const pressure_event = try pressure_actor.completeRouted(
        pressure_routed.operation,
        pressure_completion,
    );
    try std.testing.expectEqual(@as(usize, "recovered".len), pressure_event.sent.length);
    var recovered: ["recovered".len]u8 = undefined;
    try std.testing.expectEqual(
        recovered.len,
        try syscallLength(linux.read(pressure_sockets[1], &recovered, recovered.len)),
    );
    try std.testing.expectEqualSlices(u8, "recovered", &recovered);

    for (states) |state| {
        try reactor.destroyPeer(state.peer);
        _ = linux.close(state.remote);
    }
    try reactor.destroyPeer(pressure_peer);
    _ = linux.close(pressure_sockets[1]);
    try std.testing.expectEqual(@as(usize, 0), reactor.slots.active_count);
    try std.testing.expectEqual(
        @as(usize, backpressure_connections * 4),
        reactor.transmit_blocks.available(),
    );
    try std.testing.expectEqual(
        @as(usize, backpressure_connections),
        reactor.descriptors.available(),
    );
}

test "close cancels a send blocked by kernel backpressure" {
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 8 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = backpressure_block_size,
        .transmit_block_count = 2,
        .descriptor_count = 1,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(std.testing.allocator);

    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &sockets,
    ));
    defer _ = linux.close(sockets[1]);
    try setSendBuffer(sockets[0], 4096);
    const peer = try reactor.attachReceiving(sockets[0], .{
        .received_fd_budget = 0,
        .transmit_byte_budget = 2 * backpressure_block_size,
        .transmit_fd_budget = 1,
    });
    const actor = try reactor.getActor(peer);
    var payload: [backpressure_block_size]u8 = undefined;
    @memset(&payload, 0xa5);
    const descriptor = try createDescriptor();
    try actor.enqueue(&payload, &.{descriptor});
    try actor.enqueue(&payload, &.{});

    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit_and_wait(1);
    const first_completion = try reactor.ring.copy_cqe();
    const first_routed = (reactor.route(null, first_completion) orelse
        return error.InvalidCompletion).connection;
    if (first_routed.operation != .send) return error.UnexpectedCompletion;
    const first_event = try actor.completeRouted(.send, first_completion);
    try std.testing.expect(first_event.sent.length < 2 * backpressure_block_size);
    try std.testing.expect(first_event.sent.more_queued);

    try reactor.prepareSend(peer);
    try std.testing.expectError(error.SendAlreadyActive, reactor.prepareSend(peer));
    _ = try reactor.ring.submit();
    try std.testing.expect(try reactor.prepareClose(peer));
    _ = try reactor.ring.submit();
    var send_stopped = false;
    var receive_stopped = false;
    var cancel_complete = false;
    while (!actor.canDeinit()) {
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const routed_peer = reactor.routedPeer(routed);
        try std.testing.expectEqual(peer.slot, routed_peer.slot);
        try std.testing.expectEqual(peer.generation, routed_peer.generation);
        const event = try actor.completeRouted(routed.operation, completion);
        switch (event) {
            .send_stopped => send_stopped = true,
            .receive_stopped => receive_stopped = true,
            .cancel_complete => cancel_complete = true,
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(send_stopped);
    try std.testing.expect(receive_stopped);
    try std.testing.expect(cancel_complete);
    try reactor.destroyPeer(peer);
    try std.testing.expectEqual(@as(usize, 2), reactor.transmit_blocks.available());
    try std.testing.expectEqual(@as(usize, 1), reactor.descriptors.available());
}

const receive_pressure_connections = 4;
const receive_pressure_buffers = 2;
const receive_pressure_bytes = 512;

const ReceivePressureState = struct {
    peer: wayring.io_uring.Peer,
    remote: linux.fd_t,
    pattern: u8,
    received: usize = 0,
    received_fds: usize = 0,
};

const HeldReceive = struct {
    state: *ReceivePressureState,
    received: wayring.io_uring.Receiver.Received,
    buffer_id: u16,
};

test "real io_uring receives recover from shared buffer exhaustion" {
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 16 }, .{
        .receive_buffer_size = 256,
        .receive_buffer_count = receive_pressure_buffers,
        .receive_control_capacity = 64,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 1,
        .descriptor_count = receive_pressure_connections,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(std.testing.allocator);
    var states: [receive_pressure_connections]ReceivePressureState = undefined;
    var payload: [receive_pressure_bytes]u8 = undefined;

    for (&states, 0..) |*state, index| {
        var sockets: [2]linux.fd_t = undefined;
        try expectSuccess(linux.socketpair(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            0,
            &sockets,
        ));
        state.* = .{
            .peer = try reactor.attachReceiving(sockets[0], .{
                .received_fd_budget = 1,
                .transmit_byte_budget = 64,
                .transmit_fd_budget = 0,
            }),
            .remote = sockets[1],
            .pattern = @intCast(index + 0x40),
        };
        @memset(&payload, state.pattern);
        const descriptor = try createDescriptor();
        try sendWithDescriptor(state.remote, &payload, descriptor);
        _ = linux.close(descriptor);
    }
    _ = try reactor.ring.submit();

    var held: [receive_pressure_buffers]HeldReceive = undefined;
    var held_count: usize = 0;
    var saw_exhaustion = false;
    var exhaustion_completions: usize = 0;
    var completions: usize = 0;
    while (held_count < held.len or !saw_exhaustion) {
        completions += 1;
        if (completions > 100) return error.CompletionLimitExceeded;
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        if (routed.operation != .receive) return error.UnexpectedCompletion;
        const state = findReceivePressureState(&states, reactor.routedPeer(routed)) orelse
            return error.UnknownPeer;
        const actor = try reactor.getActor(state.peer);
        const event = try actor.completeRouted(.receive, completion);
        switch (event) {
            .received => {
                if (held_count == held.len) return error.ExcessReceiveBuffer;
                if (completion.flags & linux.IORING_CQE_F_BUF_MORE != 0)
                    return error.IncrementalBufferNotFilled;
                const buffer_id = try completion.buffer_id();
                for (held[0..held_count]) |prior|
                    try std.testing.expect(prior.buffer_id != buffer_id);
                held[held_count] = .{
                    .state = state,
                    .received = try (try reactor.getReceiver(state.peer)).decodeCompletion(completion),
                    .buffer_id = buffer_id,
                };
                held_count += 1;
            },
            .buffers_exhausted => {
                saw_exhaustion = true;
                exhaustion_completions += 1;
                _ = try reactor.deferReceive(state.peer);
            },
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expectEqual(receive_pressure_buffers, held_count);
    try std.testing.expect(saw_exhaustion);

    for (&held) |*item| {
        const actor = try reactor.getActor(item.state.peer);
        try consumeReceivePressure(item.state, actor, item.received);
        try reactor.releaseReceived(item.state.peer, item.received);
        if (!actor.receive_active and item.state.received < receive_pressure_bytes)
            _ = try reactor.deferReceive(item.state.peer);
    }
    const initial_rearms = try reactor.prepareDeferredReceives();
    try std.testing.expect(initial_rearms > 0);
    _ = try reactor.ring.submit();

    completions = 0;
    var rearm_submissions: usize = 1;
    while (!receivePressureComplete(&states)) {
        while (true) {
            completions += 1;
            if (completions > 10_000) return error.CompletionLimitExceeded;
            const completion = try reactor.ring.copy_cqe();
            const routed = (reactor.route(null, completion) orelse
                return error.InvalidCompletion).connection;
            if (routed.operation != .receive) return error.UnexpectedCompletion;
            const state = findReceivePressureState(&states, reactor.routedPeer(routed)) orelse
                return error.UnknownPeer;
            const actor = try reactor.getActor(state.peer);
            const event = try actor.completeRouted(.receive, completion);
            switch (event) {
                .received => {
                    const receiver = try reactor.getReceiver(state.peer);
                    const received = try receiver.decodeCompletion(completion);
                    try consumeReceivePressure(state, actor, received);
                    try reactor.releaseReceived(state.peer, received);
                    if (state.received < receive_pressure_bytes and !actor.receive_active)
                        _ = try reactor.deferReceive(state.peer);
                },
                .buffers_exhausted => {
                    saw_exhaustion = true;
                    exhaustion_completions += 1;
                    if (state.received < receive_pressure_bytes)
                        _ = try reactor.deferReceive(state.peer);
                },
                else => return error.UnexpectedCompletion,
            }
            if (receivePressureComplete(&states) or reactor.ring.cq_ready() == 0) break;
        }
        if (try reactor.prepareDeferredReceives() != 0) {
            _ = try reactor.ring.submit();
            rearm_submissions += 1;
        }
    }

    for (states) |state| {
        try std.testing.expectEqual(receive_pressure_bytes, state.received);
        try std.testing.expectEqual(@as(usize, 1), state.received_fds);
    }
    try std.testing.expect(rearm_submissions < exhaustion_completions);
    for (states) |state| {
        if (!try reactor.prepareClose(state.peer)) try reactor.destroyPeer(state.peer);
    }
    _ = try reactor.ring.submit();
    completions = 0;
    while (reactor.slots.active_count != 0) {
        completions += 1;
        if (completions > 100) return error.CompletionLimitExceeded;
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const peer = reactor.routedPeer(routed);
        const actor = try reactor.getActor(peer);
        const event = try actor.completeRouted(routed.operation, completion);
        switch (event) {
            .receive_stopped, .cancel_complete, .buffers_exhausted, .disconnected => {},
            .received => {
                const receiver = try reactor.getReceiver(peer);
                const received = try receiver.decodeCompletion(completion);
                try receiver.release(received);
                return error.ExcessPayload;
            },
            else => return error.UnexpectedCompletion,
        }
        if (actor.canDeinit()) try reactor.destroyPeer(peer);
    }
    for (states) |state| _ = linux.close(state.remote);
    try std.testing.expectEqual(
        @as(usize, receive_pressure_connections),
        reactor.descriptors.available(),
    );
}

fn findReceivePressureState(
    states: []ReceivePressureState,
    peer: wayring.io_uring.Peer,
) ?*ReceivePressureState {
    for (states) |*state| {
        if (state.peer.slot == peer.slot and state.peer.generation == peer.generation)
            return state;
    }
    return null;
}

fn consumeReceivePressure(
    state: *ReceivePressureState,
    actor: *wayring.connection.Actor,
    received: wayring.io_uring.Receiver.Received,
) !void {
    const end = state.received + received.payload.len;
    if (end > receive_pressure_bytes) return error.ExcessPayload;
    for (received.payload) |byte| try std.testing.expectEqual(state.pattern, byte);
    _ = try actor.ingestControl(received.control);
    while (actor.takeFd()) |fd| {
        try expectCloseOnExec(fd);
        _ = linux.close(fd);
        state.received_fds += 1;
    } else |err| if (err != error.Empty) return err;
    state.received = end;
}

fn receivePressureComplete(states: []const ReceivePressureState) bool {
    for (states) |state| if (state.received != receive_pressure_bytes) return false;
    return true;
}

test "non-incremental recvmsg cycles provided buffers with payloads and descriptors" {
    const buffer_count = 8;
    const completion_count = 33;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(std.testing.allocator, .{ .entries = 8 }, .{
        .receive_buffer_size = 4096,
        .receive_buffer_count = buffer_count,
        .receive_control_capacity = 512,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 1,
        .descriptor_count = 1,
        .send_descriptor_capacity = 1,
    });
    defer reactor.deinit(std.testing.allocator);

    var sockets: [2]linux.fd_t = undefined;
    try expectSuccess(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &sockets,
    ));
    defer _ = linux.close(sockets[1]);
    const peer = try reactor.attachReceiving(sockets[0], .{
        .received_fd_budget = 1,
        .transmit_byte_budget = 64,
        .transmit_fd_budget = 1,
    });
    const actor = try reactor.getActor(peer);
    const receiver = try reactor.getReceiver(peer);
    _ = try reactor.ring.submit();

    for (0..completion_count) |index| {
        const descriptor = try createDescriptor();
        const expected_value: u64 = index + 1;
        try std.testing.expectEqual(
            @sizeOf(u64),
            try syscallLength(linux.write(
                descriptor,
                std.mem.asBytes(&expected_value).ptr,
                @sizeOf(u64),
            )),
        );
        const payload = [_]u8{ 0xa5, @intCast(index) };
        try sendWithDescriptor(sockets[1], &payload, descriptor);
        _ = linux.close(descriptor);

        const completion = try reactor.ring.copy_cqe();
        if (completion.err() == .FAULT) return error.UnexpectedEFAULT;
        try std.testing.expect(completion.res > 0);
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        try std.testing.expectEqual(peer, reactor.routedPeer(routed));
        try std.testing.expectEqual(wayring.completion.Operation.receive, routed.operation);
        const event = try actor.completeRouted(routed.operation, completion);
        try std.testing.expect(event.received.more);

        const received = try receiver.decodeCompletion(completion);
        try std.testing.expectEqualSlices(u8, &payload, received.payload);
        try std.testing.expectEqual(@as(usize, 1), try actor.ingestControl(received.control));
        const received_fd = try actor.takeFd();
        defer _ = linux.close(received_fd);
        try expectCloseOnExec(received_fd);
        var actual_value: u64 = 0;
        try std.testing.expectEqual(
            @sizeOf(u64),
            try syscallLength(linux.read(
                received_fd,
                std.mem.asBytes(&actual_value).ptr,
                @sizeOf(u64),
            )),
        );
        try std.testing.expectEqual(expected_value, actual_value);
        try std.testing.expectError(error.Empty, actor.takeFd());
        try std.testing.expectEqual(@as(u16, @intCast(index % buffer_count)), try completion.buffer_id());
        try std.testing.expectEqual(@as(u32, 0), completion.flags & linux.IORING_CQE_F_BUF_MORE);
        try reactor.releaseReceived(peer, received);
    }

    try std.testing.expect(try reactor.prepareClose(peer));
    _ = try reactor.ring.submit();
    while (!actor.canDeinit()) {
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const event = try actor.completeRouted(routed.operation, completion);
        switch (event) {
            .receive_stopped, .cancel_complete => {},
            else => return error.UnexpectedCompletion,
        }
    }
    try reactor.destroyPeer(peer);
    try std.testing.expectEqual(@as(usize, 1), reactor.descriptors.available());
}

fn prepareBackpressureSend(
    reactor: *wayring.io_uring.Reactor,
    state: *BackpressureState,
) !void {
    const actor = try reactor.getActor(state.peer);
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try actor.transmit.snapshot(&descriptor_scratch, &control);
    state.in_flight = snapshot.byteCount();
    try reactor.prepareSend(state.peer);
}

fn findBackpressureState(
    states: []BackpressureState,
    peer: wayring.io_uring.Peer,
) ?*BackpressureState {
    for (states) |*state| {
        if (state.peer.slot == peer.slot and state.peer.generation == peer.generation)
            return state;
    }
    return null;
}

fn drainBackpressure(
    state: *BackpressureState,
    received_pool: *wayring.pool.SharedFds,
) !void {
    var queue = wayring.ancillary.FdQueue.init(received_pool, 1);
    defer queue.deinit();
    var bytes: [16 * 1024]u8 = undefined;
    while (state.received < state.sent) {
        const wanted = @min(bytes.len, state.sent - state.received);
        var iov: std.posix.iovec = .{ .base = &bytes, .len = wanted };
        var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var message: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iov),
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const count = try syscallLength(linux.recvmsg(
            state.remote,
            &message,
            linux.MSG.CMSG_CLOEXEC,
        ));
        if (count == 0) return error.UnexpectedEof;
        if (message.flags & (linux.MSG.TRUNC | linux.MSG.CTRUNC) != 0)
            return error.TruncatedMessage;
        for (bytes[0..count]) |byte| try std.testing.expectEqual(state.pattern, byte);
        _ = try wayring.ancillary.enqueueRights(control[0..message.controllen], &queue);
        while (queue.pop()) |fd| {
            try expectCloseOnExec(fd);
            _ = linux.close(fd);
            state.received_fds += 1;
        } else |err| if (err != error.Empty) return err;
        state.received += count;
    }
}

fn setSendBuffer(fd: linux.fd_t, size: i32) !void {
    try expectSuccess(linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.SNDBUF,
        std.mem.asBytes(&size).ptr,
        @sizeOf(i32),
    ));
}
