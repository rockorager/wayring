const std = @import("std");
const wayring = @import("wayring");
const benchmark_protocol = @import("benchmark_protocol");

const c = std.c;
const linux = std.os.linux;
const wire = wayring.wire;
const ancillary = wayring.ancillary;
const completions = wayring.completion;
const connection = wayring.connection;
const reactor = wayring.reactor;
const objects = wayring.objects;
const dispatch = wayring.dispatch;
const IoReactor = wayring.io_uring.Reactor;
const MultishotReceiver = wayring.io_uring.Receiver;
const Benchmark = benchmark_protocol.wp_wayring_benchmark_v1;

const object_id = 2;
const message_size = 12;
const recv_buffer_size = 64 * 1024;
const ring_entries = 8;
const multi_ring_entries = 256;
const max_connections = 64;
const recv_buffer_count = 8;
const control_size = 256;
const buffer_group_id = 1;
const actor_slot = 0;
const recv_tag = (completions.Token{
    .operation = .receive,
    .slot = 0,
    .generation = 1,
}).encode();
const send_tag = (completions.Token{
    .operation = .send,
    .slot = 0,
    .generation = 1,
}).encode();

const Options = struct {
    const Mode = enum { round_trip, latency, client_tx, client_rx };

    warmup: u64 = 100_000,
    messages: u64 = 1_000_000,
    batch: u32 = 256,
    connections: usize = 1,
    mode: Mode = .round_trip,
};

const Ring = struct {
    io: linux.IoUring,

    fn init(entries: u16) !Ring {
        const flags = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN;
        return .{ .io = try linux.IoUring.init(entries, flags) };
    }

    fn deinit(ring: *Ring) void {
        ring.io.deinit();
    }

    fn sendAll(ring: *Ring, fd: c.fd_t, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var iov: std.posix.iovec_const = .{
                .base = bytes[offset..].ptr,
                .len = bytes.len - offset,
            };
            var message: linux.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&iov),
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            _ = try ring.io.sendmsg(send_tag, fd, &message, 0);
            _ = try ring.io.submit_and_wait(1);
            const completion = try ring.io.copy_cqe();
            if (completion.user_data != send_tag or completion.res < 0)
                return error.InvalidCompletion;
            if (completion.res == 0) return error.Disconnected;
            offset += @intCast(completion.res);
        }
    }

    fn sendWithFds(ring: *Ring, fd: c.fd_t, bytes: []const u8, fds: []const linux.fd_t) !void {
        var iov: std.posix.iovec_const = .{ .base = bytes.ptr, .len = bytes.len };
        var control_storage: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const control = try ancillary.encodeRights(&control_storage, fds);
        var message: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iov),
            .iovlen = 1,
            .control = control.ptr,
            .controllen = control.len,
            .flags = 0,
        };
        _ = try ring.io.sendmsg(send_tag, fd, &message, 0);
        _ = try ring.io.submit_and_wait(1);
        const completion = try ring.io.copy_cqe();
        if (completion.user_data != send_tag or completion.res <= 0)
            return error.InvalidCompletion;
        const sent: usize = @intCast(completion.res);
        if (sent < bytes.len) try ring.sendAll(fd, bytes[sent..]);
    }

    fn receive(ring: *Ring, fd: c.fd_t, bytes: []u8, control: []u8) !usize {
        var iov: std.posix.iovec = .{ .base = bytes.ptr, .len = bytes.len };
        var message: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iov),
            .iovlen = 1,
            .control = control.ptr,
            .controllen = control.len,
            .flags = 0,
        };
        _ = try ring.io.recvmsg(recv_tag, fd, &message, linux.MSG.CMSG_CLOEXEC);
        _ = try ring.io.submit_and_wait(1);
        const completion = try ring.io.copy_cqe();
        if (completion.user_data != recv_tag or completion.res < 0)
            return error.InvalidCompletion;
        if (completion.res == 0) return error.Disconnected;
        if (message.flags & (linux.MSG.CTRUNC | linux.MSG.TRUNC) != 0)
            return error.InvalidMessage;
        return @intCast(completion.res);
    }
};

fn flushActorSend(
    owner: *IoReactor,
    peer: wayring.io_uring.Peer,
    actor: *connection.Actor,
) !void {
    while (actor.transmit.queuedBytes() > 0) {
        try owner.prepareSend(peer);
        _ = try owner.ring.submit_and_wait(1);

        const cqe = try owner.ring.copy_cqe();
        const routed = owner.slots.route(cqe.user_data) orelse return error.InvalidCompletion;
        if (routed.operation != .send) return error.InvalidCompletion;
        const event = try actor.completeRouted(routed.operation, cqe);
        switch (event) {
            .sent => {},
            else => return error.InvalidCompletion,
        }
    }
}

fn flushMultiActorSend(
    ring: *linux.IoUring,
    owner: *IoReactor,
    target_slot: usize,
    actors: []connection.Actor,
    receivers: []MultishotReceiver,
    fds: []const c.fd_t,
) !void {
    const actor = &actors[target_slot];
    const peer: wayring.io_uring.Peer = .{
        .slot = actor.slot,
        .generation = actor.generation,
    };
    while (actor.transmit.queuedBytes() > 0) {
        try owner.prepareSend(peer);
        _ = try ring.submit_and_wait(1);

        while (true) {
            const cqe = try ring.copy_cqe();
            const routed = owner.slots.route(cqe.user_data) orelse return error.InvalidCompletion;
            const routed_slot: usize = routed.slot;
            const routed_actor = &actors[routed_slot];
            const event = try routed_actor.completeRouted(routed.operation, cqe);
            switch (routed.operation) {
                .send => {
                    if (routed_slot != target_slot) return error.InvalidCompletion;
                    switch (event) {
                        .sent => break,
                        else => return error.InvalidCompletion,
                    }
                },
                .receive => switch (event) {
                    .buffers_exhausted => try receivers[routed_slot].arm(
                        ring,
                        fds[routed_slot],
                        routed_actor,
                    ),
                    else => return error.InvalidCompletion,
                },
                .cancel => return error.InvalidCompletion,
                .accept, .accept_cancel => return error.InvalidCompletion,
            }
        }
    }
}

fn sendActorResponse(
    owner: *IoReactor,
    peer: wayring.io_uring.Peer,
    actor: *connection.Actor,
    sequence: u32,
) !void {
    try Benchmark.encodeEvent(&actor.transmit, object_id, .{
        .pong = .{ .sequence = sequence },
    });
    try flushActorSend(owner, peer, actor);
}

fn encodeMessage(bytes: *[message_size]u8, opcode: u16, sequence: u32) !void {
    try (wire.Header{
        .object_id = object_id,
        .opcode = opcode,
        .size = message_size,
    }).encode(bytes[0..wire.header_len]);
    std.mem.writeInt(u32, bytes[wire.header_len..message_size], sequence, nativeEndian());
}

fn nativeEndian() std.builtin.Endian {
    return @import("builtin").cpu.arch.endian();
}

fn receiveMessage(ring: *Ring, fd: c.fd_t, storage: *[message_size]u8) !u32 {
    var filled: usize = 0;
    var control: [256]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    while (filled < storage.len) {
        filled += try ring.receive(fd, storage[filled..], &control);
    }

    const message = (try wire.Message.decode(storage)) orelse return error.InvalidMessage;
    if (message.header.object_id != object_id or message.header.opcode != 0)
        return error.InvalidMessage;
    var arguments = message.arguments();
    const sequence = try arguments.uint();
    try arguments.finish();
    return sequence;
}

fn sendPhase(
    allocator: std.mem.Allocator,
    ring: *Ring,
    fd: c.fd_t,
    count: u64,
    batch: u32,
    sequence: u32,
) !void {
    const capacity = try std.math.mul(usize, batch, message_size);
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);

    var remaining = count;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, batch));
        for (0..chunk) |index| {
            const start = index * message_size;
            try encodeMessage(buffer[start..][0..message_size], 0, sequence);
        }
        try ring.sendAll(fd, buffer[0 .. chunk * message_size]);
        remaining -= chunk;
    }

    var response: [message_size]u8 = undefined;
    if (try receiveMessage(ring, fd, &response) != sequence)
        return error.InvalidMessage;
}

fn clientTransmitPhase(
    owner: *IoReactor,
    peer: wayring.io_uring.Peer,
    actor: *connection.Actor,
    count: u64,
    batch: u32,
    sequence: u32,
) !void {
    var remaining = count;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, batch));
        for (0..chunk) |_| try Benchmark.encodeRequest(
            &actor.transmit,
            object_id,
            .{ .ping = .{ .sequence = sequence } },
        );
        try flushActorSend(owner, peer, actor);
        remaining -= chunk;
    }
}

fn readExact(fd: c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.read(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.SystemCallFailed,
        }
        if (result == 0) return error.Disconnected;
        offset += result;
    }
}

fn writeExact(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.SystemCallFailed,
        }
        if (result == 0) return error.Disconnected;
        offset += result;
    }
}

fn rawDrainPhase(fd: c.fd_t, count: u64, acknowledgement: u8) !void {
    var storage: [64 * 1024]u8 = undefined;
    var remaining = try std.math.mul(u64, count, message_size);
    while (remaining > 0) {
        const wanted: usize = @intCast(@min(remaining, storage.len));
        try readExact(fd, storage[0..wanted]);
        remaining -= wanted;
    }
    const result = linux.write(fd, @ptrCast(&acknowledgement), 1);
    if (linux.errno(result) != .SUCCESS or result != 1)
        return error.SystemCallFailed;
}

fn waitForRawDrain(fd: c.fd_t, acknowledgement: u8) !void {
    var received: [1]u8 = undefined;
    try readExact(fd, &received);
    if (received[0] != acknowledgement) return error.InvalidMessage;
}

fn clientTransmitMain(options: Options) !u8 {
    var sockets: [2]c.fd_t = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        rawDrainPhase(sockets[1], options.warmup, 1) catch c._exit(1);
        rawDrainPhase(sockets[1], options.messages, 2) catch c._exit(1);
        _ = c.close(sockets[1]);
        c._exit(0);
    }
    _ = c.close(sockets[1]);

    const allocator = std.heap.c_allocator;
    const transmit_capacity = try std.math.mul(usize, options.batch, message_size);
    const transmit_blocks = try std.math.divCeil(usize, transmit_capacity, 4096);
    var owner: IoReactor = undefined;
    try owner.initOwned(allocator, .{ .entries = ring_entries }, .{
        .max_connections = 1,
        .buffer_group_id = buffer_group_id,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = control_size,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 4096,
        .transmit_block_count = @max(transmit_blocks, 1),
        .descriptor_count = 1,
        .send_descriptor_capacity = 1,
    });
    const peer = try owner.attach(sockets[0], .{
        .received_fd_budget = 0,
        .transmit_byte_budget = transmit_capacity,
        .transmit_fd_budget = 0,
    });
    const actor = try owner.getActor(peer);

    try clientTransmitPhase(&owner, peer, actor, options.warmup, options.batch, 1);
    try waitForRawDrain(sockets[0], 1);
    const start = try monotonicNs();
    try clientTransmitPhase(&owner, peer, actor, options.messages, options.batch, 2);
    try waitForRawDrain(sockets[0], 2);
    const elapsed = try monotonicNs() - start;

    try owner.destroyPeer(peer);
    owner.deinit(allocator);
    var status: c_int = 0;
    if (c.waitpid(child, &status, 0) != child or
        !c.W.IFEXITED(@bitCast(status)) or c.W.EXITSTATUS(@bitCast(status)) != 0)
        return error.SystemCallFailed;
    _ = c.printf(
        "backend=wayring scope=client-tx messages=%llu batch=%u elapsed_ns=%llu messages_per_second=%.0f\n",
        options.messages,
        options.batch,
        elapsed,
        @as(f64, @floatFromInt(options.messages)) * @as(f64, std.time.ns_per_s) /
            @as(f64, @floatFromInt(elapsed)),
    );
    return 0;
}

fn rawWritePhase(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    count: u64,
    batch: u32,
    sequence: u32,
) !void {
    const capacity = try std.math.mul(usize, batch, message_size);
    const storage = try allocator.alloc(u8, capacity);
    defer allocator.free(storage);
    var remaining = count;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, batch));
        for (0..chunk) |index| try encodeMessage(
            storage[index * message_size ..][0..message_size],
            0,
            sequence,
        );
        try writeExact(fd, storage[0 .. chunk * message_size]);
        remaining -= chunk;
    }
}

const ClientEventHandler = struct {
    count: u64 = 0,
    sequence: u32,

    pub fn event(
        handler: *ClientEventHandler,
        _: objects.Dispatch,
        message: wire.Message,
        fds: *ancillary.FdQueue,
    ) !dispatch.Control {
        const decoded = try Benchmark.decodeEvent(message, fds);
        const sequence = switch (decoded) {
            .pong => |pong| pong.sequence,
            .pong_fd => return error.InvalidMessage,
        };
        if (sequence != handler.sequence) return error.InvalidMessage;
        handler.count += 1;
        return .continue_dispatch;
    }
};

fn clientReceivePhase(
    owner: *IoReactor,
    peer: wayring.io_uring.Peer,
    namespace: *objects.Namespace,
    count: u64,
    sequence: u32,
) !void {
    const actor = try owner.getActor(peer);
    const receiver = try owner.getReceiver(peer);
    var handler: ClientEventHandler = .{ .sequence = sequence };
    while (handler.count < count) {
        const completion = try owner.ring.copy_cqe();
        const routed = owner.route(null, completion).?.connection;
        if (owner.routedPeer(routed).slot != peer.slot or routed.operation != .receive)
            return error.InvalidCompletion;
        const event = try actor.completeRouted(routed.operation, completion);
        switch (event) {
            .received => {
                _ = try dispatch.receivedEvents(
                    actor,
                    namespace,
                    receiver,
                    completion,
                    &handler,
                );
                if (handler.count > count) return error.InvalidMessage;
            },
            .buffers_exhausted => {},
            else => return error.InvalidCompletion,
        }
        if (!actor.receive_active) try owner.armReceive(peer);
    }
}

fn clientReceiveMain(options: Options) !u8 {
    var sockets: [2]c.fd_t = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        const allocator = std.heap.c_allocator;
        rawWritePhase(allocator, sockets[1], options.warmup, options.batch, 1) catch c._exit(1);
        var acknowledgement: [1]u8 = undefined;
        readExact(sockets[1], &acknowledgement) catch c._exit(1);
        if (acknowledgement[0] != 1) c._exit(1);
        rawWritePhase(allocator, sockets[1], options.messages, options.batch, 2) catch c._exit(1);
        readExact(sockets[1], &acknowledgement) catch c._exit(1);
        if (acknowledgement[0] != 2) c._exit(1);
        _ = c.close(sockets[1]);
        c._exit(0);
    }
    _ = c.close(sockets[1]);

    const allocator = std.heap.c_allocator;
    var owner: IoReactor = undefined;
    try owner.initOwned(allocator, .{ .entries = ring_entries }, .{
        .max_connections = 1,
        .buffer_group_id = buffer_group_id,
        .receive_buffer_size = recv_buffer_size,
        .receive_buffer_count = recv_buffer_count,
        .receive_control_capacity = control_size,
        .fragment_block_size = wire.max_message_len,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 1,
        .descriptor_count = 1,
        .send_descriptor_capacity = 1,
    });
    const peer = try owner.attach(sockets[0], .{
        .received_fd_budget = 0,
        .transmit_byte_budget = 1,
        .transmit_fd_budget = 0,
    });
    const actor = try owner.getActor(peer);
    const receiver = try owner.getReceiver(peer);
    var namespace = try objects.Namespace.init(allocator, 1);
    _ = try namespace.insert(object_id, &Benchmark.info, Benchmark.info.version, null);
    try owner.armReceive(peer);

    try clientReceivePhase(&owner, peer, &namespace, options.warmup, 1);
    try writeExact(sockets[0], &.{1});
    const start = try monotonicNs();
    try clientReceivePhase(&owner, peer, &namespace, options.messages, 2);
    const elapsed = try monotonicNs() - start;
    try writeExact(sockets[0], &.{2});

    try receiver.stop(owner.ring, owner.slots, actor);
    try owner.destroyPeer(peer);
    namespace.deinit(allocator);
    owner.deinit(allocator);
    var status: c_int = 0;
    if (c.waitpid(child, &status, 0) != child or
        !c.W.IFEXITED(@bitCast(status)) or c.W.EXITSTATUS(@bitCast(status)) != 0)
        return error.SystemCallFailed;
    _ = c.printf(
        "backend=wayring scope=client-rx messages=%llu batch=%u elapsed_ns=%llu messages_per_second=%.0f\n",
        options.messages,
        options.batch,
        elapsed,
        @as(f64, @floatFromInt(options.messages)) * @as(f64, std.time.ns_per_s) /
            @as(f64, @floatFromInt(elapsed)),
    );
    return 0;
}

fn validateFdLane(ring: *Ring, fd: c.fd_t) !void {
    var request: [message_size]u8 = undefined;
    try encodeMessage(&request, 1, 0);
    try ring.sendWithFds(fd, &request, &.{fd});

    var response: [message_size]u8 = undefined;
    if (try receiveMessage(ring, fd, &response) != 0)
        return error.InvalidMessage;
}

fn server(fd: c.fd_t, options: Options) !void {
    const allocator = std.heap.c_allocator;
    var owner: IoReactor = undefined;
    try owner.initOwned(allocator, .{ .entries = ring_entries }, .{
        .max_connections = 1,
        .buffer_group_id = buffer_group_id,
        .receive_buffer_size = recv_buffer_size,
        .receive_buffer_count = recv_buffer_count,
        .receive_control_capacity = control_size,
        .fragment_block_size = wire.max_message_len,
        .fragment_block_count = 4,
        .transmit_block_size = 4096,
        .transmit_block_count = 4,
        .descriptor_count = 32,
        .send_descriptor_capacity = 16,
    });
    const ring = owner.ring;
    const peer = try owner.attach(fd, .{
        .received_fd_budget = 16,
        .transmit_byte_budget = 16 * 1024,
        .transmit_fd_budget = 16,
    });
    const actor = try owner.getActor(peer);
    const receiver = try owner.getReceiver(peer);
    const slots = owner.slots;
    var namespace = try objects.Namespace.init(allocator, 8);
    _ = try namespace.insert(object_id, &Benchmark.info, Benchmark.info.version, null);
    try receiver.arm(
        ring,
        fd,
        actor,
    );
    var framer = actor.framer;

    var received: u64 = 0;
    var next_ack = options.warmup;
    const final_ack = options.warmup + options.messages;

    while (received < final_ack) {
        const input = try receiver.next(ring, fd, slots, actor);
        defer receiver.release(input) catch {};
        _ = try actor.ingestControl(input.control);
        var payload = input.payload;
        while (try framer.next(&payload)) |message| {
            if (message.header.object_id != object_id or message.header.opcode > 1)
                return error.InvalidMessage;

            if (message.header.opcode == 1) {
                var arguments = message.arguments();
                const sequence = try arguments.uint();
                try arguments.finish();
                if (received != 0 or sequence != 0 or actor.received_fds.len() != 1)
                    return error.InvalidMessage;
                const received_fd = try actor.takeFd();
                const descriptor_flags = linux.fcntl(received_fd, linux.F.GETFD, 0);
                const valid_fd = linux.errno(descriptor_flags) == .SUCCESS and
                    descriptor_flags & linux.FD_CLOEXEC != 0;
                _ = linux.close(received_fd);
                if (!valid_fd) return error.InvalidMessage;
                try sendActorResponse(&owner, peer, actor, sequence);
                continue;
            }

            _ = try namespace.request(message.header.object_id, message.header.opcode);
            const request = try Benchmark.decodeRequest(message, &actor.received_fds);
            const sequence = switch (request) {
                .ping => |ping| ping.sequence,
                .ping_fd => return error.InvalidMessage,
            };
            received += 1;
            if (received == next_ack) {
                try sendActorResponse(&owner, peer, actor, sequence);
                next_ack = final_ack;
            }
        }
    }

    actor.framer = framer;
    try receiver.stop(ring, slots, actor);
    try owner.destroyPeer(peer);
    namespace.deinit(allocator);
    owner.deinit(allocator);
}

const MultiInput = struct {
    slot: usize,
    received: MultishotReceiver.Received,
};

fn nextMultiInput(
    ring: *linux.IoUring,
    owner: *IoReactor,
    fds: []const c.fd_t,
    actors: []connection.Actor,
    receivers: []MultishotReceiver,
) !MultiInput {
    while (true) {
        const cqe = try ring.copy_cqe();
        const token = completions.Token.decode(cqe.user_data) catch
            return error.InvalidCompletion;
        const routed = owner.slots.routeToken(token) orelse continue;
        if (routed.operation != .receive) return error.InvalidCompletion;
        const slot: usize = routed.slot;
        const actor = &actors[slot];
        const receiver = &receivers[slot];
        const event = try actor.completeRouted(routed.operation, cqe);
        switch (event) {
            .received => return .{
                .slot = slot,
                .received = try receiver.decodeCompletion(cqe),
            },
            .buffers_exhausted => try receiver.arm(ring, fds[slot], actor),
            else => return error.InvalidCompletion,
        }
    }
}

fn finishMultiInput(
    ring: *linux.IoUring,
    fd: c.fd_t,
    actor: *connection.Actor,
    receiver: *MultishotReceiver,
    input: MultishotReceiver.Received,
) !void {
    try receiver.release(input);
    if (!actor.receive_active) try receiver.arm(ring, fd, actor);
}

fn serverMultiHandshake(
    ring: *linux.IoUring,
    owner: *IoReactor,
    fds: []const c.fd_t,
    actors: []connection.Actor,
    receivers: []MultishotReceiver,
    namespaces: []objects.SharedNamespace,
) !void {
    const input = try nextMultiInput(ring, owner, fds, actors, receivers);
    const actor = &actors[input.slot];
    const receiver = &receivers[input.slot];
    if (input.slot != 0) return error.InvalidMessage;
    _ = try actor.ingestControl(input.received.control);
    var payload = input.received.payload;
    const message = (try actor.nextMessage(&payload)) orelse return error.InvalidMessage;
    if (payload.len != 0 or message.header.object_id != object_id or message.header.opcode != 1 or
        namespaces[input.slot].get(object_id) == null)
        return error.InvalidMessage;
    var arguments = message.arguments();
    if (try arguments.uint() != 0) return error.InvalidMessage;
    try arguments.finish();
    if (actor.received_fds.len() != 1) return error.InvalidMessage;
    const received_fd = try actor.takeFd();
    const descriptor_flags = linux.fcntl(received_fd, linux.F.GETFD, 0);
    const valid_fd = linux.errno(descriptor_flags) == .SUCCESS and
        descriptor_flags & linux.FD_CLOEXEC != 0;
    _ = linux.close(received_fd);
    if (!valid_fd) return error.InvalidMessage;
    try finishMultiInput(ring, fds[0], actor, receiver, input.received);
    try Benchmark.encodeEvent(&actor.transmit, object_id, .{
        .pong = .{ .sequence = 0 },
    });
    try flushMultiActorSend(ring, owner, 0, actors, receivers, fds);
}

fn serverMultiPhase(
    ring: *linux.IoUring,
    owner: *IoReactor,
    fds: []const c.fd_t,
    actors: []connection.Actor,
    receivers: []MultishotReceiver,
    namespaces: []objects.SharedNamespace,
    counts: []u64,
    target: u64,
    sequence: u32,
) !void {
    @memset(counts, 0);
    var completed: usize = 0;
    while (completed < actors.len) {
        const input = try nextMultiInput(ring, owner, fds, actors, receivers);
        const actor = &actors[input.slot];
        const receiver = &receivers[input.slot];
        _ = try actor.ingestControl(input.received.control);
        var payload = input.received.payload;
        var context: BenchmarkRequestHandler = .{
            .count = &counts[input.slot],
            .completed = &completed,
            .target = target,
            .sequence = sequence,
        };
        _ = try dispatch.requests(
            actor,
            &namespaces[input.slot],
            &payload,
            &context,
        );
        try finishMultiInput(ring, fds[input.slot], actor, receiver, input.received);
    }

    for (actors) |*actor| try Benchmark.encodeEvent(&actor.transmit, object_id, .{
        .pong = .{ .sequence = sequence },
    });
    for (fds, 0..) |_, index| try flushMultiActorSend(
        ring,
        owner,
        index,
        actors,
        receivers,
        fds,
    );
}

const BenchmarkRequestHandler = struct {
    count: *u64,
    completed: *usize,
    target: u64,
    sequence: u32,

    pub fn request(
        handler: *BenchmarkRequestHandler,
        _: objects.Dispatch,
        message: wire.Message,
        fds: *ancillary.FdQueue,
    ) !dispatch.Control {
        const decoded = try Benchmark.decodeRequest(message, fds);
        const decoded_sequence = switch (decoded) {
            .ping => |ping| ping.sequence,
            .ping_fd => return error.InvalidMessage,
        };
        if (decoded_sequence != handler.sequence) return error.InvalidMessage;
        handler.count.* += 1;
        if (handler.count.* > handler.target) return error.InvalidMessage;
        if (handler.count.* == handler.target) handler.completed.* += 1;
        return .continue_dispatch;
    }
};

fn stopMulti(
    ring: *linux.IoUring,
    slots: reactor.Slots,
    actors: []connection.Actor,
    receivers: []MultishotReceiver,
) !void {
    var receive_remaining: usize = 0;
    var cancel_remaining: usize = 0;
    for (actors, receivers) |*actor, *receiver| {
        if (try receiver.prepareStop(ring, actor)) {
            receive_remaining += 1;
            cancel_remaining += 1;
        }
    }
    if (cancel_remaining > 0) _ = try ring.submit();

    while (receive_remaining > 0 or cancel_remaining > 0) {
        const cqe = try ring.copy_cqe();
        const routed = slots.route(cqe.user_data) orelse return error.InvalidCompletion;
        const slot: usize = routed.slot;
        const actor = &actors[slot];
        const was_receiving = actor.receive_active;
        const event = try actor.completeRouted(routed.operation, cqe);
        switch (routed.operation) {
            .receive => {
                if (cqe.res > 0 and cqe.flags & linux.IORING_CQE_F_BUFFER != 0)
                    try receivers[slot].buffers.put(cqe);
                switch (event) {
                    .received, .receive_stopped, .buffers_exhausted, .disconnected => {},
                    else => return error.InvalidCompletion,
                }
                if (was_receiving and !actor.receive_active) receive_remaining -= 1;
            },
            .cancel => {
                switch (event) {
                    .cancel_complete => {
                        cancel_remaining -= 1;
                    },
                    else => return error.InvalidCompletion,
                }
            },
            .send => return error.InvalidCompletion,
            .accept, .accept_cancel => return error.InvalidCompletion,
        }
    }
}

fn serverMulti(fds: []const c.fd_t, options: Options) !void {
    const allocator = std.heap.c_allocator;
    const receive_buffer_count = try std.math.ceilPowerOfTwo(
        u16,
        @intCast(@max(recv_buffer_count, options.connections * 2)),
    );
    var owner: IoReactor = undefined;
    try owner.initOwned(allocator, .{ .entries = multi_ring_entries }, .{
        .max_connections = options.connections,
        .buffer_group_id = buffer_group_id,
        .receive_buffer_size = recv_buffer_size,
        .receive_buffer_count = receive_buffer_count,
        .receive_control_capacity = control_size,
        .fragment_block_size = wire.max_message_len,
        .fragment_block_count = @max(4, options.connections / 4),
        .transmit_block_size = 4096,
        .transmit_block_count = options.connections,
        .descriptor_count = @max(32, options.connections * 4),
        .send_descriptor_capacity = 16,
    });
    const ring = owner.ring;
    const slots = owner.slots;
    const actors = owner.actor_storage[0..options.connections];
    const receivers = owner.receiver_storage[0..options.connections];
    const counts = try allocator.alloc(u64, options.connections);
    defer allocator.free(counts);
    var object_pool = try objects.SharedObjectPool.init(allocator, options.connections);
    const object_buckets = try allocator.alloc(
        objects.SharedObjectBucket,
        options.connections * 8,
    );
    defer allocator.free(object_buckets);
    @memset(object_buckets, .{});
    const namespaces = try allocator.alloc(objects.SharedNamespace, options.connections);
    defer allocator.free(namespaces);

    for (namespaces, 0..) |*namespace, index| {
        const slot: u24 = @intCast(index);
        const peer = try owner.attach(fds[index], .{
            .received_fd_budget = 16,
            .transmit_byte_budget = 16 * 1024,
            .transmit_fd_budget = 16,
        });
        if (peer.slot != slot) return error.InvalidSlot;
        const actor = &actors[index];
        const receiver = &receivers[index];
        namespace.* = try objects.SharedNamespace.init(
            &object_pool,
            object_buckets[index * 8 ..][0..8],
            actor.generation,
            1,
        );
        _ = try namespace.insert(object_id, &Benchmark.info, Benchmark.info.version, null);
        try receiver.prepare(ring, fds[index], actor);
    }
    _ = try ring.submit();

    try serverMultiHandshake(ring, &owner, fds, actors, receivers, namespaces);
    if (options.mode == .latency) {
        for (0..options.warmup) |round| try serverMultiPhase(
            ring,
            &owner,
            fds,
            actors,
            receivers,
            namespaces,
            counts,
            1,
            @intCast(round + 1),
        );
        for (0..options.messages) |round| try serverMultiPhase(
            ring,
            &owner,
            fds,
            actors,
            receivers,
            namespaces,
            counts,
            1,
            @intCast(options.warmup + round + 1),
        );
    } else {
        try serverMultiPhase(ring, &owner, fds, actors, receivers, namespaces, counts, options.warmup, 1);
        try serverMultiPhase(ring, &owner, fds, actors, receivers, namespaces, counts, options.messages, 2);
    }

    try stopMulti(ring, slots, actors, receivers);
    for (actors, namespaces) |*actor, *namespace| {
        const peer: wayring.io_uring.Peer = .{
            .slot = actor.slot,
            .generation = actor.generation,
        };
        try owner.destroyPeer(peer);
        namespace.deinit();
    }
    object_pool.deinit(allocator);
    owner.deinit(allocator);
}

fn monotonicNs() !u64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC_RAW, &time)) != .SUCCESS)
        return error.SystemCallFailed;
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(time.nsec));
}

fn sendMultiPhase(
    allocator: std.mem.Allocator,
    ring: *Ring,
    fds: []const c.fd_t,
    count: u64,
    batch: u32,
    sequence: u32,
) !void {
    const capacity = try std.math.mul(usize, batch, message_size);
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);
    const iovecs = try allocator.alloc(std.posix.iovec_const, fds.len);
    defer allocator.free(iovecs);
    const messages = try allocator.alloc(linux.msghdr_const, fds.len);
    defer allocator.free(messages);
    const written = try allocator.alloc(usize, fds.len);
    defer allocator.free(written);

    var remaining = count;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, batch));
        const byte_count = chunk * message_size;
        for (0..chunk) |index| {
            const start = index * message_size;
            try encodeMessage(buffer[start..][0..message_size], 0, sequence);
        }
        @memset(written, std.math.maxInt(usize));
        for (fds, 0..) |fd, index| {
            iovecs[index] = .{ .base = buffer.ptr, .len = byte_count };
            messages[index] = .{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&iovecs[index]),
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const submission = try ring.io.get_sqe();
            submission.prep_sendmsg(fd, &messages[index], 0);
            submission.user_data = index;
        }
        _ = try ring.io.submit_and_wait(@intCast(fds.len));
        for (0..fds.len) |_| {
            const cqe = try ring.io.copy_cqe();
            if (cqe.user_data >= fds.len or cqe.res <= 0)
                return error.InvalidCompletion;
            const index: usize = @intCast(cqe.user_data);
            if (written[index] != std.math.maxInt(usize)) return error.InvalidCompletion;
            written[index] = @intCast(cqe.res);
        }
        for (fds, written) |fd, sent| {
            if (sent > byte_count) return error.InvalidCompletion;
            if (sent < byte_count) try ring.sendAll(fd, buffer[sent..byte_count]);
        }
        remaining -= chunk;
    }

    for (fds) |fd| {
        var response: [message_size]u8 = undefined;
        if (try receiveMessage(ring, fd, &response) != sequence)
            return error.InvalidMessage;
    }
}

fn latencyMultiRound(
    ring: *Ring,
    fds: []const c.fd_t,
    sequence: u32,
    request: *[message_size]u8,
    iovecs: []std.posix.iovec_const,
    messages: []linux.msghdr_const,
    written: []usize,
) !void {
    try encodeMessage(request, 0, sequence);
    @memset(written, std.math.maxInt(usize));
    for (fds, 0..) |fd, index| {
        iovecs[index] = .{ .base = request, .len = request.len };
        messages[index] = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iovecs[index]),
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const submission = try ring.io.get_sqe();
        submission.prep_sendmsg(fd, &messages[index], 0);
        submission.user_data = index;
    }
    _ = try ring.io.submit_and_wait(@intCast(fds.len));
    for (0..fds.len) |_| {
        const cqe = try ring.io.copy_cqe();
        if (cqe.user_data >= fds.len or cqe.res <= 0)
            return error.InvalidCompletion;
        const index: usize = @intCast(cqe.user_data);
        if (written[index] != std.math.maxInt(usize)) return error.InvalidCompletion;
        written[index] = @intCast(cqe.res);
    }
    for (fds, written) |fd, sent| {
        if (sent > request.len) return error.InvalidCompletion;
        if (sent < request.len) try ring.sendAll(fd, request[sent..]);
    }
    for (fds) |fd| {
        var response: [message_size]u8 = undefined;
        if (try receiveMessage(ring, fd, &response) != sequence)
            return error.InvalidMessage;
    }
}

fn percentile(samples: []const u64, percent: usize) u64 {
    const rank = (samples.len * percent + 99) / 100;
    return samples[if (rank == 0) 0 else rank - 1];
}

fn runMultiLatency(
    allocator: std.mem.Allocator,
    ring: *Ring,
    fds: []const c.fd_t,
    options: Options,
) !void {
    const iovecs = try allocator.alloc(std.posix.iovec_const, fds.len);
    defer allocator.free(iovecs);
    const messages = try allocator.alloc(linux.msghdr_const, fds.len);
    defer allocator.free(messages);
    const written = try allocator.alloc(usize, fds.len);
    defer allocator.free(written);
    const samples = try allocator.alloc(u64, @intCast(options.messages));
    defer allocator.free(samples);
    var request: [message_size]u8 = undefined;

    for (0..options.warmup) |round| try latencyMultiRound(
        ring,
        fds,
        @intCast(round + 1),
        &request,
        iovecs,
        messages,
        written,
    );
    var sum: u128 = 0;
    for (samples, 0..) |*sample, round| {
        const start = try monotonicNs();
        try latencyMultiRound(
            ring,
            fds,
            @intCast(options.warmup + round + 1),
            &request,
            iovecs,
            messages,
            written,
        );
        sample.* = try monotonicNs() - start;
        sum += sample.*;
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const operations = try std.math.mul(u64, options.messages, options.connections);
    _ = c.printf(
        "backend=wayring-multishot connections=%zu latency_scope=round_trip_all rounds=%llu operations=%llu mean_ns=%.0f p50_ns=%llu p95_ns=%llu p99_ns=%llu max_ns=%llu\n",
        options.connections,
        options.messages,
        operations,
        @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(options.messages)),
        percentile(samples, 50),
        percentile(samples, 95),
        percentile(samples, 99),
        samples[samples.len - 1],
    );
}

fn multiMain(options: Options) !u8 {
    const allocator = std.heap.c_allocator;
    const pairs = try allocator.alloc([2]c.fd_t, options.connections);
    defer allocator.free(pairs);
    const parent_fds = try allocator.alloc(c.fd_t, options.connections);
    defer allocator.free(parent_fds);
    const child_fds = try allocator.alloc(c.fd_t, options.connections);
    defer allocator.free(child_fds);
    for (pairs, parent_fds, child_fds) |*pair, *parent_fd, *child_fd| {
        if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, pair) != 0)
            return error.SystemCallFailed;
        parent_fd.* = pair[0];
        child_fd.* = pair[1];
    }

    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        for (parent_fds) |fd| _ = c.close(fd);
        serverMulti(child_fds, options) catch |err| {
            const name = @errorName(err);
            _ = c.write(2, name.ptr, name.len);
            _ = c.write(2, "\n", 1);
            c._exit(1);
        };
        c._exit(0);
    }
    for (child_fds) |fd| _ = c.close(fd);

    var ring = try Ring.init(multi_ring_entries);
    defer ring.deinit();
    try validateFdLane(&ring, parent_fds[0]);
    if (options.mode == .latency) {
        try runMultiLatency(allocator, &ring, parent_fds, options);
    } else {
        try sendMultiPhase(allocator, &ring, parent_fds, options.warmup, options.batch, 1);
        const start = try monotonicNs();
        try sendMultiPhase(allocator, &ring, parent_fds, options.messages, options.batch, 2);
        const elapsed = try monotonicNs() - start;
        const total_messages = try std.math.mul(u64, options.messages, options.connections);
        _ = c.printf(
            "backend=wayring-multishot connections=%zu messages=%llu batch=%u elapsed_ns=%llu messages_per_second=%.0f\n",
            options.connections,
            total_messages,
            options.batch,
            elapsed,
            @as(f64, @floatFromInt(total_messages)) * @as(f64, std.time.ns_per_s) /
                @as(f64, @floatFromInt(elapsed)),
        );
    }
    for (parent_fds) |fd| _ = c.close(fd);

    var status: c_int = 0;
    if (c.waitpid(child, &status, 0) != child or
        !c.W.IFEXITED(@bitCast(status)) or c.W.EXITSTATUS(@bitCast(status)) != 0)
        return error.SystemCallFailed;
    return 0;
}

fn parseOptions(args: std.process.Args) !Options {
    var options: Options = .{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.skip();
    if (iterator.next()) |value| options.messages = try std.fmt.parseUnsigned(u64, value, 10);
    if (iterator.next()) |value| options.batch = try std.fmt.parseUnsigned(u32, value, 10);
    if (iterator.next()) |value| options.warmup = try std.fmt.parseUnsigned(u64, value, 10);
    if (iterator.next()) |value| options.connections = try std.fmt.parseUnsigned(usize, value, 10);
    if (iterator.next()) |value| {
        if (std.mem.eql(u8, value, "latency"))
            options.mode = .latency
        else if (std.mem.eql(u8, value, "client-tx"))
            options.mode = .client_tx
        else if (std.mem.eql(u8, value, "client-rx"))
            options.mode = .client_rx
        else
            return error.InvalidMessage;
    }
    if (options.messages == 0 or options.batch == 0 or options.warmup == 0 or
        options.connections == 0 or options.connections > max_connections or
        (options.mode == .latency and
            options.messages > std.math.maxInt(u32) - options.warmup) or
        ((options.mode == .client_tx or options.mode == .client_rx) and
            options.connections != 1))
        return error.InvalidMessage;
    return options;
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const options = try parseOptions(init.args);
    if (options.mode == .client_tx) return clientTransmitMain(options);
    if (options.mode == .client_rx) return clientReceiveMain(options);
    if (options.connections > 1 or options.mode == .latency) return multiMain(options);
    var sockets: [2]c.fd_t = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;

    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        server(sockets[1], options) catch |err| {
            const name = @errorName(err);
            _ = c.write(2, name.ptr, name.len);
            _ = c.write(2, "\n", 1);
            c._exit(1);
        };
        c._exit(0);
    }
    _ = c.close(sockets[1]);

    var ring = try Ring.init(ring_entries);
    defer ring.deinit();
    const allocator = std.heap.c_allocator;

    try validateFdLane(&ring, sockets[0]);
    try sendPhase(allocator, &ring, sockets[0], options.warmup, options.batch, 1);
    const start = try monotonicNs();
    try sendPhase(allocator, &ring, sockets[0], options.messages, options.batch, 2);
    const elapsed = try monotonicNs() - start;
    _ = c.close(sockets[0]);

    _ = c.printf(
        "backend=wayring-multishot messages=%llu batch=%u elapsed_ns=%llu messages_per_second=%.0f\n",
        options.messages,
        options.batch,
        elapsed,
        @as(f64, @floatFromInt(options.messages)) * @as(f64, std.time.ns_per_s) /
            @as(f64, @floatFromInt(elapsed)),
    );

    var status: c_int = 0;
    if (c.waitpid(child, &status, 0) != child or
        !c.W.IFEXITED(@bitCast(status)) or c.W.EXITSTATUS(@bitCast(status)) != 0)
        return error.SystemCallFailed;
    return 0;
}
