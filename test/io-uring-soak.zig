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
        .max_connections = max_connections,
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
