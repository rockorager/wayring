//! Persistent io_uring operation state used by connection actors.

const std = @import("std");
const linux = std.os.linux;
const ancillary = @import("ancillary.zig");
const completions = @import("completion.zig");
const connection = @import("connection.zig");
const pools = @import("pool.zig");
const reactor = @import("reactor.zig");

pub const Config = struct {
    max_connections: usize,
    buffer_group_id: u16 = 1,
    receive_buffer_size: u32,
    receive_buffer_count: u16,
    receive_control_capacity: usize,
    fragment_block_size: usize,
    fragment_block_count: usize,
    transmit_block_size: usize,
    transmit_block_count: usize,
    descriptor_count: usize,
    send_descriptor_capacity: usize,
};

pub const RingConfig = struct {
    entries: u16,
    flags: u32 = linux.IORING_SETUP_SINGLE_ISSUER |
        linux.IORING_SETUP_DEFER_TASKRUN,
};

pub const ActorConfig = struct {
    received_fd_budget: usize,
    transmit_byte_budget: usize,
    transmit_fd_budget: usize,
};

pub const CompletionTarget = union(enum) {
    listener,
    connection: reactor.Routed,
};

pub const Peer = struct {
    slot: u24,
    generation: u32,
};

pub const SendState = struct {
    descriptor_scratch: []linux.fd_t,
    control_storage: []u8,
    iovecs: [2]std.posix.iovec_const = undefined,
    message: linux.msghdr_const = undefined,

    pub inline fn prepare(
        sender: *SendState,
        ring: *linux.IoUring,
        fd: linux.fd_t,
        actor: *connection.Actor,
    ) !void {
        try prepareSendOperation(
            sender.descriptor_scratch,
            sender.control_storage,
            &sender.iovecs,
            &sender.message,
            ring,
            fd,
            actor,
        );
    }
};

/// Owns all reactor-wide kernel and userspace storage. Connections borrow from
/// these pools and perform no allocator calls during message processing.
pub const Reactor = struct {
    ring: *linux.IoUring,
    owned_ring: linux.IoUring,
    owns_ring: bool,
    receive_buffers: linux.IoUring.BufferGroup,
    slot_storage: []reactor.Slot,
    slots: reactor.Slots,
    actor_storage: []connection.Actor,
    receiver_storage: []Receiver,
    fd_storage: []linux.fd_t,
    sender_storage: []SendState,
    send_descriptor_storage: []linux.fd_t,
    send_control_storage: []align(@alignOf(linux.cmsghdr)) u8,
    send_descriptor_capacity: usize,
    send_control_stride: usize,
    fragment_blocks: pools.SharedBlocks,
    transmit_blocks: pools.SharedBlocks,
    descriptors: pools.SharedFds,
    buffer_group_id: u16,
    receive_control_capacity: usize,

    /// `owner` must remain at the same address until `deinit`, because Zig's
    /// provided-buffer group retains a pointer to its parent ring.
    pub fn initOwned(
        owner: *Reactor,
        allocator: std.mem.Allocator,
        ring_config: RingConfig,
        config: Config,
    ) !void {
        if (!validConfig(config)) return error.InvalidConfig;

        owner.owned_ring = try linux.IoUring.init(ring_config.entries, ring_config.flags);
        errdefer owner.owned_ring.deinit();
        owner.ring = &owner.owned_ring;
        owner.owns_ring = true;
        try owner.initResources(allocator, config);
    }

    /// Registers Wayring's provided buffers on a caller-owned ring. `ring` and
    /// `owner` must both retain stable addresses until `deinit` returns.
    pub fn initBorrowed(
        owner: *Reactor,
        allocator: std.mem.Allocator,
        ring: *linux.IoUring,
        config: Config,
    ) !void {
        if (!validConfig(config)) return error.InvalidConfig;

        owner.ring = ring;
        owner.owns_ring = false;
        try owner.initResources(allocator, config);
    }

    fn initResources(
        owner: *Reactor,
        allocator: std.mem.Allocator,
        config: Config,
    ) !void {
        owner.receive_buffers = try linux.IoUring.BufferGroup.init(
            owner.ring,
            allocator,
            config.buffer_group_id,
            config.receive_buffer_size,
            config.receive_buffer_count,
        );
        errdefer owner.receive_buffers.deinit(allocator);
        owner.slot_storage = try allocator.alloc(reactor.Slot, config.max_connections);
        errdefer allocator.free(owner.slot_storage);
        owner.slots = reactor.Slots.init(owner.slot_storage);
        owner.actor_storage = try allocator.alloc(connection.Actor, config.max_connections);
        errdefer allocator.free(owner.actor_storage);
        owner.receiver_storage = try allocator.alloc(Receiver, config.max_connections);
        errdefer allocator.free(owner.receiver_storage);
        owner.fd_storage = try allocator.alloc(linux.fd_t, config.max_connections);
        errdefer allocator.free(owner.fd_storage);
        owner.sender_storage = try allocator.alloc(SendState, config.max_connections);
        errdefer allocator.free(owner.sender_storage);
        const send_descriptor_count = std.math.mul(
            usize,
            config.max_connections,
            config.send_descriptor_capacity,
        ) catch return error.CapacityOverflow;
        owner.send_descriptor_storage = try allocator.alloc(
            linux.fd_t,
            send_descriptor_count,
        );
        errdefer allocator.free(owner.send_descriptor_storage);
        owner.send_control_stride = try ancillary.rightsControlSize(
            config.send_descriptor_capacity,
        );
        const send_control_size = std.math.mul(
            usize,
            config.max_connections,
            owner.send_control_stride,
        ) catch return error.CapacityOverflow;
        owner.send_control_storage = try allocator.alignedAlloc(
            u8,
            .of(linux.cmsghdr),
            send_control_size,
        );
        errdefer allocator.free(owner.send_control_storage);
        owner.send_descriptor_capacity = config.send_descriptor_capacity;
        for (owner.sender_storage, 0..) |*sender, index| {
            const descriptor_start = index * owner.send_descriptor_capacity;
            const control_start = index * owner.send_control_stride;
            sender.* = .{
                .descriptor_scratch = owner.send_descriptor_storage[descriptor_start..][0..owner.send_descriptor_capacity],
                .control_storage = owner.send_control_storage[control_start..][0..owner.send_control_stride],
            };
        }
        owner.fragment_blocks = try pools.SharedBlocks.init(
            allocator,
            config.fragment_block_size,
            config.fragment_block_count,
        );
        errdefer owner.fragment_blocks.deinit(allocator);
        owner.transmit_blocks = try pools.SharedBlocks.init(
            allocator,
            config.transmit_block_size,
            config.transmit_block_count,
        );
        errdefer owner.transmit_blocks.deinit(allocator);
        owner.descriptors = try pools.SharedFds.init(allocator, config.descriptor_count);
        owner.buffer_group_id = config.buffer_group_id;
        owner.receive_control_capacity = config.receive_control_capacity;
    }

    pub fn deinit(owner: *Reactor, allocator: std.mem.Allocator) void {
        std.debug.assert(owner.slots.active_count == 0);
        owner.descriptors.deinit(allocator);
        owner.transmit_blocks.deinit(allocator);
        owner.fragment_blocks.deinit(allocator);
        allocator.free(owner.send_control_storage);
        allocator.free(owner.send_descriptor_storage);
        allocator.free(owner.sender_storage);
        allocator.free(owner.fd_storage);
        allocator.free(owner.receiver_storage);
        allocator.free(owner.actor_storage);
        allocator.free(owner.slot_storage);
        owner.receive_buffers.deinit(allocator);
        if (owner.owns_ring) owner.ring.deinit();
        owner.* = undefined;
    }

    /// Consumes `fd`, including when connection capacity is exhausted.
    pub fn attach(
        owner: *Reactor,
        socket_fd: linux.fd_t,
        config: ActorConfig,
    ) !Peer {
        if (config.transmit_fd_budget > owner.send_descriptor_capacity) {
            _ = linux.close(socket_fd);
            return error.SendDescriptorCapacityExceeded;
        }
        const acquired = owner.slots.acquire() catch |err| {
            _ = linux.close(socket_fd);
            return err;
        };
        const index: usize = acquired.index;
        owner.actor_storage[index] = connection.Actor.initSharedFragments(
            acquired.index,
            acquired.generation,
            &owner.fragment_blocks,
            &owner.descriptors,
            config.received_fd_budget,
            &owner.transmit_blocks,
            config.transmit_byte_budget,
            config.transmit_fd_budget,
        );
        owner.receiver_storage[index] = Receiver.init(
            &owner.receive_buffers,
            owner.buffer_group_id,
            owner.receive_control_capacity,
        );
        owner.fd_storage[index] = socket_fd;
        return .{ .slot = acquired.index, .generation = acquired.generation };
    }

    /// Consumes a connected descriptor and queues its first receive without
    /// submitting, allowing client connections to join a shared SQE batch.
    pub fn attachReceiving(
        owner: *Reactor,
        socket_fd: linux.fd_t,
        config: ActorConfig,
    ) !Peer {
        const peer = try owner.attach(socket_fd, config);
        errdefer owner.destroyPeer(peer) catch unreachable;
        try owner.prepareReceive(peer);
        return peer;
    }

    /// Consumes the accepted descriptor even when slot admission fails.
    pub fn admit(
        owner: *Reactor,
        accepted: Listener.Accepted,
        actor_config: ActorConfig,
    ) !Peer {
        return owner.attach(accepted.fd, actor_config);
    }

    /// Consumes an accepted descriptor and queues its first receive without
    /// submitting, allowing a batch of admissions to share one enter call.
    pub fn admitReceiving(
        owner: *Reactor,
        accepted: Listener.Accepted,
        actor_config: ActorConfig,
    ) !Peer {
        return owner.attachReceiving(accepted.fd, actor_config);
    }

    pub inline fn prepareReceive(owner: *Reactor, peer: Peer) !void {
        const actor = try owner.getActor(peer);
        const receiver = &owner.receiver_storage[peer.slot];
        try receiver.prepare(owner.ring, owner.fd_storage[peer.slot], actor);
    }

    pub inline fn armReceive(owner: *Reactor, peer: Peer) !void {
        try owner.prepareReceive(peer);
        _ = try owner.ring.submit();
    }

    /// Moves a peer to closing and queues receive cancellation without
    /// submitting, allowing many peers to share one ring enter. Returns false
    /// when no receive operation needs cancellation.
    pub inline fn prepareClose(owner: *Reactor, peer: Peer) !bool {
        const actor = try owner.getActor(peer);
        return owner.receiver_storage[peer.slot].prepareStop(owner.ring, actor);
    }

    pub inline fn armClose(owner: *Reactor, peer: Peer) !bool {
        const queued = try owner.prepareClose(peer);
        if (queued) _ = try owner.ring.submit();
        return queued;
    }

    /// Releases an idle peer and closes its socket. Active receive or send
    /// operations must first complete their asynchronous teardown.
    pub fn destroyPeer(owner: *Reactor, peer: Peer) !void {
        const peer_actor = try owner.getActor(peer);
        if (!peer_actor.canDeinit()) return error.ActorBusy;
        try owner.slots.deactivate(peer.slot, peer.generation);
        peer_actor.deinit();
        _ = linux.close(owner.fd_storage[peer.slot]);
    }

    pub fn getActor(owner: *Reactor, peer: Peer) !*connection.Actor {
        _ = try owner.slots.token(peer.slot, peer.generation, .receive);
        return &owner.actor_storage[peer.slot];
    }

    pub fn getReceiver(owner: *Reactor, peer: Peer) !*Receiver {
        _ = try owner.slots.token(peer.slot, peer.generation, .receive);
        return &owner.receiver_storage[peer.slot];
    }

    pub fn getFd(owner: *Reactor, peer: Peer) !linux.fd_t {
        _ = try owner.slots.token(peer.slot, peer.generation, .receive);
        return owner.fd_storage[peer.slot];
    }

    pub fn getSender(owner: *Reactor, peer: Peer) !*SendState {
        _ = try owner.slots.token(peer.slot, peer.generation, .send);
        return &owner.sender_storage[peer.slot];
    }

    pub inline fn prepareSend(owner: *Reactor, peer: Peer) !void {
        const actor = try owner.getActor(peer);
        try owner.sender_storage[peer.slot].prepare(
            owner.ring,
            owner.fd_storage[peer.slot],
            actor,
        );
    }

    pub inline fn armSend(owner: *Reactor, peer: Peer) !void {
        try owner.prepareSend(peer);
        _ = try owner.ring.submit();
    }

    pub inline fn routedPeer(owner: *const Reactor, routed: reactor.Routed) Peer {
        return .{
            .slot = routed.slot,
            .generation = owner.actor_storage[routed.slot].generation,
        };
    }

    /// Classifies a Wayring completion before any actor storage is accessed.
    /// Listener operations take precedence even when their token's reserved
    /// slot zero currently belongs to a connection. On a borrowed ring, callers
    /// must reserve low user_data bytes 1 through 5 for Wayring and filter their
    /// unrelated CQEs before calling this function.
    pub inline fn route(
        owner: *const Reactor,
        listener: ?*const Listener,
        cqe: linux.io_uring_cqe,
    ) ?CompletionTarget {
        const token_value = completions.Token.decode(cqe.user_data) catch return null;
        return switch (token_value.operation) {
            .accept, .accept_cancel => if (listener) |active_listener| blk: {
                if (active_listener.owns(token_value)) break :blk .listener;
                if (token_value.operation == .accept) Listener.closeAccepted(cqe);
                break :blk null;
            } else blk: {
                if (token_value.operation == .accept) Listener.closeAccepted(cqe);
                break :blk null;
            },
            .receive, .send, .cancel => if (owner.slots.routeToken(token_value)) |routed|
                .{ .connection = routed }
            else
                null,
        };
    }

    fn validConfig(config: Config) bool {
        const receive_overhead = @sizeOf(linux.io_uring_recvmsg_out) +
            @import("wire.zig").header_len;
        return config.max_connections > 0 and
            config.max_connections <= @as(usize, std.math.maxInt(u24)) + 1 and
            config.receive_buffer_size > 0 and
            config.receive_buffer_size >= receive_overhead and
            config.receive_control_capacity <= config.receive_buffer_size - receive_overhead and
            config.receive_buffer_count > 0 and
            std.math.isPowerOfTwo(config.receive_buffer_count) and
            config.fragment_block_size > 0 and
            config.fragment_block_count > 0 and
            config.fragment_block_count <= std.math.maxInt(u32) and
            config.transmit_block_size > 0 and
            config.transmit_block_count > 0 and
            config.transmit_block_count <= std.math.maxInt(u32) and
            config.descriptor_count > 0 and
            config.descriptor_count <= std.math.maxInt(u32) and
            config.send_descriptor_capacity > 0;
    }
};

test "reactor rejects invalid shared storage before creating a ring" {
    var owner: Reactor = undefined;
    const config: Config = .{
        .max_connections = 1,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 3,
        .receive_control_capacity = 256,
        .fragment_block_size = 4096,
        .fragment_block_count = 1,
        .transmit_block_size = 4096,
        .transmit_block_count = 1,
        .descriptor_count = 1,
        .send_descriptor_capacity = 1,
    };
    try std.testing.expectError(
        error.InvalidConfig,
        owner.initOwned(std.testing.allocator, .{ .entries = 8 }, config),
    );
    var oversized_control = config;
    oversized_control.receive_buffer_count = 4;
    oversized_control.receive_control_capacity = 4096;
    try std.testing.expectError(
        error.InvalidConfig,
        owner.initOwned(std.testing.allocator, .{ .entries = 8 }, oversized_control),
    );
}

test "borrowed reactor unregisters resources without closing caller ring" {
    const allocator = std.testing.allocator;
    var ring = try linux.IoUring.init(
        8,
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN,
    );
    defer ring.deinit();

    var owner: Reactor = undefined;
    try owner.initBorrowed(allocator, &ring, .{
        .max_connections = 1,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = 256,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 1,
        .descriptor_count = 2,
        .send_descriptor_capacity = 2,
    });
    var owner_live = true;
    defer if (owner_live) owner.deinit(allocator);
    try std.testing.expect(owner.ring == &ring);
    try std.testing.expect(!owner.owns_ring);

    owner.deinit(allocator);
    owner_live = false;
    const user_data = 0x1234;
    _ = try ring.nop(user_data);
    _ = try ring.submit_and_wait(1);
    const cqe = try ring.copy_cqe();
    try std.testing.expectEqual(@as(u64, user_data), cqe.user_data);
    try std.testing.expectEqual(@as(i32, 0), cqe.res);
}

test "reactor admits peers and closes descriptors rejected by capacity" {
    const allocator = std.testing.allocator;
    var owner: Reactor = undefined;
    try owner.initOwned(allocator, .{ .entries = 8 }, .{
        .max_connections = 1,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = 256,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 1,
        .descriptor_count = 4,
        .send_descriptor_capacity = 2,
    });
    defer owner.deinit(allocator);

    var first_pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &first_pair,
    )));
    defer _ = linux.close(first_pair[1]);
    const actor_config: ActorConfig = .{
        .received_fd_budget = 2,
        .transmit_byte_budget = 64,
        .transmit_fd_budget = 2,
    };
    const peer = try owner.attachReceiving(first_pair[0], actor_config);
    var peer_live = true;
    try std.testing.expectEqual(@as(u24, 0), peer.slot);
    const peer_actor = try owner.getActor(peer);
    const peer_receiver = try owner.getReceiver(peer);
    defer if (peer_live) {
        if (peer_actor.receive_active)
            peer_receiver.stop(owner.ring, owner.slots, peer_actor) catch unreachable;
        owner.destroyPeer(peer) catch unreachable;
    };
    try std.testing.expectEqual(peer.generation, peer_actor.generation);
    try std.testing.expect(peer_actor.receive_active);
    _ = try owner.ring.submit();
    const payload = "12345678";
    const write_result = linux.write(first_pair[1], payload, payload.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(write_result));
    try std.testing.expectEqual(payload.len, write_result);
    const cqe = try owner.ring.copy_cqe();
    const routed = owner.route(null, cqe).?.connection;
    try std.testing.expectEqual(peer, owner.routedPeer(routed));
    const event = try peer_actor.completeRouted(routed.operation, cqe);
    try std.testing.expect(event.received.length >= payload.len);
    const received = try peer_receiver.decodeCompletion(cqe);
    try std.testing.expectEqualSlices(u8, payload, received.payload);
    try peer_receiver.release(received);

    try peer_actor.enqueue("abcdefgh", &.{});
    try peer_actor.enqueue("ABCDEFGH", &.{});
    try owner.armSend(peer);
    var sent_bytes: [16]u8 = undefined;
    const read_result = linux.read(first_pair[1], &sent_bytes, sent_bytes.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(read_result));
    try std.testing.expectEqual(sent_bytes.len, read_result);
    try std.testing.expectEqualSlices(u8, "abcdefghABCDEFGH", &sent_bytes);
    const send_cqe = try owner.ring.copy_cqe();
    const send_routed = owner.route(null, send_cqe).?.connection;
    try std.testing.expectEqual(completions.Operation.send, send_routed.operation);
    const send_event = try peer_actor.completeRouted(send_routed.operation, send_cqe);
    try std.testing.expectEqual(sent_bytes.len, send_event.sent.length);
    try std.testing.expect(!send_event.sent.more_queued);
    try std.testing.expect(try owner.prepareClose(peer));
    try std.testing.expectError(error.CancelAlreadyActive, owner.prepareClose(peer));
    _ = try owner.ring.submit();
    while (!peer_actor.canDeinit()) {
        const close_cqe = try owner.ring.copy_cqe();
        const close_routed = owner.route(null, close_cqe).?.connection;
        const close_event = try peer_actor.completeRouted(close_routed.operation, close_cqe);
        switch (close_routed.operation) {
            .receive => switch (close_event) {
                .receive_stopped, .disconnected, .buffers_exhausted => {},
                .received => try peer_receiver.buffers.put(close_cqe),
                else => return error.UnexpectedCompletion,
            },
            .cancel => try std.testing.expectEqual(
                connection.Event.cancel_complete,
                close_event,
            ),
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(peer_actor.canDeinit());

    var oversized_pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &oversized_pair,
    )));
    defer _ = linux.close(oversized_pair[1]);
    var oversized_config = actor_config;
    oversized_config.transmit_fd_budget += 1;
    try std.testing.expectError(error.SendDescriptorCapacityExceeded, owner.attach(
        oversized_pair[0],
        oversized_config,
    ));
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(oversized_pair[0], linux.F.GETFD, 0)),
    );

    var second_pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &second_pair,
    )));
    defer _ = linux.close(second_pair[1]);
    try std.testing.expectError(error.Exhausted, owner.admit(
        .{ .fd = second_pair[0], .more = true },
        actor_config,
    ));
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(second_pair[0], linux.F.GETFD, 0)),
    );

    try owner.destroyPeer(peer);
    peer_live = false;
    try std.testing.expectError(error.SlotInactive, owner.getActor(peer));
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(first_pair[0], linux.F.GETFD, 0)),
    );
}

test "selected recvmsg detects stream EOF behind its metadata prefix" {
    const allocator = std.testing.allocator;
    var owner: Reactor = undefined;
    try owner.initOwned(allocator, .{ .entries = 8 }, .{
        .max_connections = 1,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 2,
        .receive_control_capacity = 256,
        .fragment_block_size = 64,
        .fragment_block_count = 1,
        .transmit_block_size = 64,
        .transmit_block_count = 1,
        .descriptor_count = 2,
        .send_descriptor_capacity = 1,
    });
    defer owner.deinit(allocator);

    var sockets: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &sockets,
    )));
    const peer = try owner.attachReceiving(sockets[0], .{
        .received_fd_budget = 1,
        .transmit_byte_budget = 64,
        .transmit_fd_budget = 1,
    });
    const actor = try owner.getActor(peer);
    const receiver = try owner.getReceiver(peer);
    _ = try owner.ring.submit();
    _ = linux.close(sockets[1]);

    const completion = try owner.ring.copy_cqe();
    const routed = (owner.route(null, completion) orelse
        return error.InvalidCompletion).connection;
    const event = try actor.completeRouted(routed.operation, completion);
    switch (event) {
        .received => {
            try std.testing.expectError(
                error.Disconnected,
                receiver.decodeCompletion(completion),
            );
            actor.beginClose();
        },
        .disconnected => {},
        else => return error.InvalidCompletion,
    }
    try std.testing.expect(actor.canDeinit());
    try owner.destroyPeer(peer);
}

/// Persistent state for one multishot accept operation. Accepted descriptor
/// ownership transfers to the caller through `Event.accepted`.
pub const Listener = struct {
    generation: u32 = 0,
    accept_tag: u64 = undefined,
    accept_active: bool = false,
    cancel_active: bool = false,
    closing: bool = false,

    pub const Accepted = struct {
        fd: linux.fd_t,
        more: bool,
    };

    pub const Event = union(enum) {
        accepted: Accepted,
        accept_stopped,
        cancel_complete,
    };

    pub inline fn prepare(
        listener: *Listener,
        ring: *linux.IoUring,
        fd: linux.fd_t,
    ) !void {
        if (listener.closing) return error.Closing;
        if (listener.accept_active) return error.AcceptAlreadyActive;
        if (listener.cancel_active) return error.CancelActive;
        const generation = completions.nextGeneration(listener.generation);
        const tag = token(generation, .accept);
        _ = try ring.accept_multishot(
            tag,
            fd,
            null,
            null,
            linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        );
        listener.generation = generation;
        listener.accept_tag = tag;
        listener.accept_active = true;
    }

    pub inline fn arm(
        listener: *Listener,
        ring: *linux.IoUring,
        fd: linux.fd_t,
    ) !void {
        try listener.prepare(ring, fd);
        _ = try ring.submit();
    }

    /// Queues cancellation without submitting so it can be batched with other
    /// reactor teardown operations. Returns false when no accept is active.
    pub fn prepareStop(listener: *Listener, ring: *linux.IoUring) !bool {
        listener.closing = true;
        if (!listener.accept_active) return false;
        if (listener.cancel_active) return error.CancelAlreadyActive;
        _ = try ring.cancel(
            token(listener.generation, .accept_cancel),
            listener.accept_tag,
            0,
        );
        listener.cancel_active = true;
        return true;
    }

    pub inline fn complete(
        listener: *Listener,
        cqe: linux.io_uring_cqe,
    ) !Event {
        const token_value = completions.Token.decode(cqe.user_data) catch
            return error.UnexpectedCompletion;
        if (token_value.slot != 0 or token_value.generation != listener.generation) {
            if (token_value.operation == .accept) closeAccepted(cqe);
            return error.StaleCompletion;
        }

        return switch (token_value.operation) {
            .accept => listener.completeAccept(cqe),
            .accept_cancel => listener.completeCancel(cqe),
            .receive, .send, .cancel => error.UnexpectedCompletion,
        };
    }

    pub fn canDeinit(listener: Listener) bool {
        return !listener.accept_active and !listener.cancel_active;
    }

    fn completeAccept(listener: *Listener, cqe: linux.io_uring_cqe) !Event {
        if (!listener.accept_active) {
            closeAccepted(cqe);
            return error.AcceptNotActive;
        }
        const more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
        listener.accept_active = more;
        if (cqe.res < 0) {
            listener.accept_active = false;
            if (listener.closing and cqe.err() == .CANCELED) return .accept_stopped;
            return error.IoFailure;
        }
        return .{ .accepted = .{ .fd = @intCast(cqe.res), .more = more } };
    }

    fn completeCancel(listener: *Listener, cqe: linux.io_uring_cqe) !Event {
        if (!listener.cancel_active) return error.CancelNotActive;
        listener.cancel_active = false;
        if (cqe.res < 0 and cqe.err() != .NOENT and cqe.err() != .ALREADY)
            return error.IoFailure;
        return .cancel_complete;
    }

    fn token(generation: u32, operation: completions.Operation) u64 {
        return (completions.Token{
            .slot = 0,
            .generation = generation,
            .operation = operation,
        }).encode();
    }

    fn owns(listener: *const Listener, token_value: completions.Token) bool {
        if (token_value.slot != 0 or token_value.generation != listener.generation)
            return false;
        return switch (token_value.operation) {
            .accept => listener.accept_active,
            .accept_cancel => listener.cancel_active,
            .receive, .send, .cancel => false,
        };
    }

    fn closeAccepted(cqe: linux.io_uring_cqe) void {
        if (cqe.res >= 0) _ = linux.close(@intCast(cqe.res));
    }
};

test "listener validates generations and tracks multishot termination" {
    var listener: Listener = .{
        .generation = 9,
        .accept_tag = (completions.Token{
            .slot = 0,
            .generation = 9,
            .operation = .accept,
        }).encode(),
        .accept_active = true,
    };
    const first = try listener.complete(.{
        .user_data = listener.accept_tag,
        .res = 17,
        .flags = linux.IORING_CQE_F_MORE,
    });
    try std.testing.expectEqual(
        Listener.Event{ .accepted = .{ .fd = 17, .more = true } },
        first,
    );
    try std.testing.expect(listener.accept_active);

    const final = try listener.complete(.{
        .user_data = listener.accept_tag,
        .res = 18,
        .flags = 0,
    });
    try std.testing.expectEqual(
        Listener.Event{ .accepted = .{ .fd = 18, .more = false } },
        final,
    );
    try std.testing.expect(listener.canDeinit());

    var stale = listener.accept_tag;
    stale += @as(u64, 1) << 32;
    try std.testing.expectError(error.StaleCompletion, listener.complete(.{
        .user_data = stale,
        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
        .flags = 0,
    }));
}

test "listener waits for both sides of cancellation" {
    const generation = 4;
    var listener: Listener = .{
        .generation = generation,
        .accept_tag = Listener.token(generation, .accept),
        .accept_active = true,
        .cancel_active = true,
        .closing = true,
    };
    try std.testing.expectEqual(Listener.Event.accept_stopped, try listener.complete(.{
        .user_data = listener.accept_tag,
        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
        .flags = 0,
    }));
    try std.testing.expect(!listener.canDeinit());
    try std.testing.expectEqual(Listener.Event.cancel_complete, try listener.complete(.{
        .user_data = Listener.token(generation, .accept_cancel),
        .res = 0,
        .flags = 0,
    }));
    try std.testing.expect(listener.canDeinit());
}

test "reactor routes listener tokens before colliding connection slots" {
    var slot_storage: [1]reactor.Slot = undefined;
    var owner: Reactor = undefined;
    owner.slots = reactor.Slots.init(&slot_storage);
    const acquired = try owner.slots.acquire();
    const listener: Listener = .{
        .generation = acquired.generation,
        .accept_tag = Listener.token(acquired.generation, .accept),
        .accept_active = true,
    };

    try std.testing.expectEqual(
        CompletionTarget.listener,
        owner.route(&listener, .{ .user_data = listener.accept_tag, .res = 17, .flags = 0 }).?,
    );
    const receive_tag = try owner.slots.token(
        acquired.index,
        acquired.generation,
        .receive,
    );
    try std.testing.expectEqual(
        CompletionTarget{ .connection = .{
            .slot = acquired.index,
            .operation = .receive,
        } },
        owner.route(&listener, .{ .user_data = receive_tag, .res = 1, .flags = 0 }).?,
    );

    var sockets: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &sockets,
    )));
    defer _ = linux.close(sockets[1]);
    const stale_accept = Listener.token(acquired.generation + 1, .accept);
    try std.testing.expectEqual(null, owner.route(&listener, .{
        .user_data = stale_accept,
        .res = sockets[0],
        .flags = 0,
    }));
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(sockets[0], linux.F.GETFD, 0)),
    );
}

test "listener accepts a real nonblocking close-on-exec socket" {
    var address: linux.sockaddr.un = .{ .path = undefined };
    @memset(&address.path, 0);
    const name = try std.fmt.bufPrint(address.path[1..], "wayring-test-{d}", .{linux.getpid()});
    const address_len: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + 1 + name.len,
    );

    const listen_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(listen_result));
    const listen_fd: linux.fd_t = @intCast(listen_result);
    defer _ = linux.close(listen_fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(
        listen_fd,
        @ptrCast(&address),
        address_len,
    )));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(listen_fd, 1)));

    var ring = try linux.IoUring.init(
        8,
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN,
    );
    defer ring.deinit();
    var listener: Listener = .{};
    try listener.arm(&ring, listen_fd);

    const client_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(client_result));
    const client_fd: linux.fd_t = @intCast(client_result);
    defer _ = linux.close(client_fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(
        client_fd,
        &address,
        address_len,
    )));

    _ = try ring.submit_and_wait(1);
    const accepted_event = try listener.complete(try ring.copy_cqe());
    const accepted = switch (accepted_event) {
        .accepted => |value| value,
        else => return error.UnexpectedCompletion,
    };
    defer _ = linux.close(accepted.fd);
    try std.testing.expect(accepted.more);
    const descriptor_flags = linux.fcntl(accepted.fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_flags));
    try std.testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);
    const status_flags = linux.fcntl(accepted.fd, linux.F.GETFL, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(status_flags));
    const status: linux.O = @bitCast(@as(u32, @intCast(status_flags)));
    try std.testing.expect(status.NONBLOCK);

    try std.testing.expect(try listener.prepareStop(&ring));
    _ = try ring.submit();
    while (!listener.canDeinit()) {
        const event = try listener.complete(try ring.copy_cqe());
        if (event == .accepted) _ = linux.close(event.accepted.fd);
    }
}

inline fn prepareSendOperation(
    descriptor_scratch: []linux.fd_t,
    control_storage: []u8,
    iovecs: *[2]std.posix.iovec_const,
    message: *linux.msghdr_const,
    ring: *linux.IoUring,
    fd: linux.fd_t,
    actor: *connection.Actor,
) !void {
    if (actor.transmit.sendActive()) return error.SendAlreadyActive;
    const snapshot = try actor.transmit.snapshot(descriptor_scratch, control_storage);
    iovecs[0] = .{
        .base = snapshot.first.ptr,
        .len = snapshot.first.len,
    };
    var iovec_count: usize = 1;
    if (snapshot.second.len > 0) {
        iovecs[1] = .{
            .base = snapshot.second.ptr,
            .len = snapshot.second.len,
        };
        iovec_count = 2;
    }
    message.* = .{
        .name = null,
        .namelen = 0,
        .iov = iovecs,
        .iovlen = iovec_count,
        .control = if (snapshot.control.len == 0) null else snapshot.control.ptr,
        .controllen = snapshot.control.len,
        .flags = 0,
    };
    const submission = try ring.get_sqe();
    const tag = try actor.beginSend(snapshot);
    submission.prep_sendmsg(fd, message, 0);
    submission.user_data = tag;
}

/// Persistent sendmsg state. One instance belongs to each connection because
/// exactly one send SQE may be active for that socket.
pub fn Sender(
    comptime descriptor_capacity: usize,
    comptime control_capacity: usize,
) type {
    return struct {
        const Self = @This();

        descriptor_scratch: [descriptor_capacity]linux.fd_t = undefined,
        control_storage: [control_capacity]u8 align(@alignOf(linux.cmsghdr)) = undefined,
        iovecs: [2]std.posix.iovec_const = undefined,
        message: linux.msghdr_const = undefined,

        pub inline fn prepare(
            sender: *Self,
            ring: *linux.IoUring,
            fd: linux.fd_t,
            actor: *connection.Actor,
        ) !void {
            try prepareSendOperation(
                &sender.descriptor_scratch,
                &sender.control_storage,
                &sender.iovecs,
                &sender.message,
                ring,
                fd,
                actor,
            );
        }

        pub inline fn arm(
            sender: *Self,
            ring: *linux.IoUring,
            fd: linux.fd_t,
            actor: *connection.Actor,
        ) !void {
            try sender.prepare(ring, fd, actor);
            _ = try ring.submit();
        }
    };
}

/// Per-connection multishot recvmsg state. Payload storage comes from one
/// reactor-wide provided-buffer group; this value owns no receive buffers.
pub const Receiver = struct {
    buffers: *linux.IoUring.BufferGroup,
    buffer_group_id: u16,
    dummy_iov: std.posix.iovec,
    message: linux.msghdr,
    receive_tag: u64,

    pub const Received = struct {
        completion: linux.io_uring_cqe,
        control: []const u8,
        payload: []const u8,
    };

    pub fn init(
        buffers: *linux.IoUring.BufferGroup,
        buffer_group_id: u16,
        control_capacity: usize,
    ) Receiver {
        return .{
            .buffers = buffers,
            .buffer_group_id = buffer_group_id,
            .dummy_iov = .{ .base = undefined, .len = 0 },
            .message = .{
                .name = null,
                .namelen = 0,
                .iov = undefined,
                .iovlen = 0,
                .control = null,
                .controllen = control_capacity,
                .flags = 0,
            },
            .receive_tag = undefined,
        };
    }

    pub inline fn arm(
        receiver: *Receiver,
        ring: *linux.IoUring,
        fd: linux.fd_t,
        actor: *connection.Actor,
    ) !void {
        try receiver.prepare(ring, fd, actor);
        _ = try ring.submit();
    }

    /// Adds a receive SQE without submitting, allowing cross-connection batch
    /// submission by the reactor.
    pub inline fn prepare(
        receiver: *Receiver,
        ring: *linux.IoUring,
        fd: linux.fd_t,
        actor: *connection.Actor,
    ) !void {
        receiver.message.iov = @ptrCast(&receiver.dummy_iov);
        const submission = try ring.get_sqe();
        receiver.receive_tag = try actor.armReceive();
        submission.prep_recvmsg_multishot(fd, &receiver.message, linux.MSG.CMSG_CLOEXEC);
        submission.flags |= linux.IOSQE_BUFFER_SELECT;
        submission.buf_index = receiver.buffer_group_id;
        submission.user_data = receiver.receive_tag;
    }

    pub fn next(
        receiver: *Receiver,
        ring: *linux.IoUring,
        fd: linux.fd_t,
        slots: reactor.Slots,
        actor: *connection.Actor,
    ) !Received {
        while (true) {
            if (!actor.receive_active) try receiver.arm(ring, fd, actor);

            const cqe = try ring.copy_cqe();
            const routed = slots.route(cqe.user_data) orelse return error.InvalidCompletion;
            if (routed.operation != .receive) return error.InvalidCompletion;
            const event = try actor.completeRouted(routed.operation, cqe);
            switch (event) {
                .received => return receiver.decodeCompletion(cqe),
                .buffers_exhausted => continue,
                else => return error.InvalidCompletion,
            }
        }
    }

    pub inline fn decodeCompletion(
        receiver: *Receiver,
        completion: linux.io_uring_cqe,
    ) !Received {
        if (completion.res < 0) return error.InvalidCompletion;
        if (completion.res == 0) return error.Disconnected;

        const bytes = try receiver.buffers.get(completion);
        errdefer receiver.buffers.put(completion) catch {};
        const prefix_size = @sizeOf(linux.io_uring_recvmsg_out) +
            receiver.message.namelen + receiver.message.controllen;
        if (bytes.len < prefix_size) return error.InvalidMessage;

        const output = std.mem.bytesAsValue(
            linux.io_uring_recvmsg_out,
            bytes[0..@sizeOf(linux.io_uring_recvmsg_out)],
        );
        const control_offset = @sizeOf(linux.io_uring_recvmsg_out) +
            receiver.message.namelen;
        if (output.controllen > receiver.message.controllen) return error.InvalidMessage;
        const control = bytes[control_offset .. control_offset + output.controllen];
        const payload = bytes[prefix_size..];
        if (output.namelen != 0 or
            output.flags & (linux.MSG.TRUNC | linux.MSG.CTRUNC) != 0 or
            output.payloadlen != payload.len)
            return error.InvalidMessage;
        if (payload.len == 0) return error.Disconnected;

        return .{ .completion = completion, .control = control, .payload = payload };
    }

    pub inline fn release(receiver: *Receiver, received: Received) !void {
        try receiver.buffers.put(received.completion);
    }

    /// Moves the actor to closing and queues cancellation without submitting.
    /// The actor remains live until both receive and cancel CQEs are routed.
    pub fn prepareStop(
        receiver: *Receiver,
        ring: *linux.IoUring,
        actor: *connection.Actor,
    ) !bool {
        actor.beginClose();
        if (!actor.receive_active) return false;
        if (actor.cancel_requested) return error.CancelAlreadyActive;

        actor.cancel_requested = true;
        actor.cancel_active = true;
        errdefer {
            actor.cancel_requested = false;
            actor.cancel_active = false;
        }
        _ = try ring.cancel(actor.cancelToken(), receiver.receive_tag, 0);
        return true;
    }

    pub fn stop(
        receiver: *Receiver,
        ring: *linux.IoUring,
        slots: reactor.Slots,
        actor: *connection.Actor,
    ) !void {
        if (!try receiver.prepareStop(ring, actor)) return;
        _ = try ring.submit();
        while (actor.receive_active or actor.cancel_active) {
            const cqe = try ring.copy_cqe();
            const routed = slots.route(cqe.user_data) orelse return error.InvalidCompletion;
            const event = try actor.completeRouted(routed.operation, cqe);
            switch (routed.operation) {
                .receive => {
                    if (cqe.res > 0 and cqe.flags & linux.IORING_CQE_F_BUFFER != 0)
                        try receiver.buffers.put(cqe);
                    switch (event) {
                        .received, .receive_stopped, .buffers_exhausted, .disconnected => {},
                        else => return error.InvalidCompletion,
                    }
                },
                .cancel => switch (event) {
                    .cancel_complete => {},
                    else => return error.InvalidCompletion,
                },
                .send => return error.InvalidCompletion,
                .accept, .accept_cancel => return error.InvalidCompletion,
            }
        }
    }
};
