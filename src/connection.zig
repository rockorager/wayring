//! Single-owner connection state machine.

const std = @import("std");
const linux = std.os.linux;
const ancillary = @import("ancillary.zig");
const completions = @import("completion.zig");
const pools = @import("pool.zig");
const stream = @import("stream.zig");
const tx = @import("tx.zig");

pub const Error = ancillary.Error || stream.Error || tx.Error || error{
    Closing,
    ProtocolErrorPending,
    NoProtocolError,
    CancelAlreadyActive,
    CancelNotActive,
    ReceiveAlreadyActive,
    ReceiveNotActive,
    StaleCompletion,
    UnexpectedCompletion,
    IoFailure,
};

pub const Lifecycle = enum(u8) {
    open,
    protocol_error,
    draining,
    closing,
};

pub const Event = union(enum) {
    received: struct {
        length: usize,
        more: bool,
    },
    sent: struct {
        length: usize,
        more_queued: bool,
    },
    disconnected,
    receive_stopped,
    send_stopped,
    buffers_exhausted,
    cancel_complete,
};

/// Mutable connection state is confined to one reactor thread. Byte blocks and
/// descriptor entries are leased from reactor-wide pools while per-connection
/// logical budgets bound queue growth without steady-state allocation.
pub const Actor = struct {
    slot: u24,
    generation: u32,
    framer: stream.Framer,
    received_fds: ancillary.FdQueue,
    transmit: tx.Queue,
    receive_active: bool = false,
    cancel_requested: bool = false,
    cancel_active: bool = false,
    lifecycle: Lifecycle = .open,

    pub fn init(
        slot: u24,
        generation: u32,
        fragment_storage: []u8,
        descriptor_pool: *pools.SharedFds,
        received_fd_budget: usize,
        transmit_blocks: *pools.SharedBlocks,
        transmit_byte_budget: usize,
        transmit_fd_budget: usize,
    ) Actor {
        std.debug.assert(generation != 0);
        return .{
            .slot = slot,
            .generation = generation,
            .framer = stream.Framer.init(fragment_storage),
            .received_fds = ancillary.FdQueue.init(descriptor_pool, received_fd_budget),
            .transmit = tx.Queue.init(
                transmit_blocks,
                transmit_byte_budget,
                descriptor_pool,
                transmit_fd_budget,
            ),
        };
    }

    pub fn initSharedFragments(
        slot: u24,
        generation: u32,
        fragment_blocks: *pools.SharedBlocks,
        descriptor_pool: *pools.SharedFds,
        received_fd_budget: usize,
        transmit_blocks: *pools.SharedBlocks,
        transmit_byte_budget: usize,
        transmit_fd_budget: usize,
    ) Actor {
        std.debug.assert(generation != 0);
        return .{
            .slot = slot,
            .generation = generation,
            .framer = stream.Framer.initShared(fragment_blocks),
            .received_fds = ancillary.FdQueue.init(descriptor_pool, received_fd_budget),
            .transmit = tx.Queue.init(
                transmit_blocks,
                transmit_byte_budget,
                descriptor_pool,
                transmit_fd_budget,
            ),
        };
    }

    pub fn deinit(actor: *Actor) void {
        std.debug.assert(actor.canDeinit());
        actor.framer.deinit();
        actor.received_fds.deinit();
        actor.transmit.deinit();
    }

    pub fn ingestControl(actor: *Actor, control: []const u8) Error!usize {
        return ancillary.enqueueRights(control, &actor.received_fds);
    }

    pub inline fn nextMessage(actor: *Actor, bytes: *[]const u8) Error!?@import("wire.zig").Message {
        return actor.framer.next(bytes);
    }

    /// Transfers ownership of the next received descriptor to the caller.
    pub fn takeFd(actor: *Actor) Error!linux.fd_t {
        return actor.received_fds.pop();
    }

    /// Transfers descriptor ownership to the actor only if the whole enqueue
    /// succeeds. Budget errors leave bytes and descriptors untouched.
    pub fn enqueue(
        actor: *Actor,
        bytes: []const u8,
        descriptors: []const linux.fd_t,
    ) Error!void {
        if (actor.lifecycle != .open) return error.Closing;
        return actor.transmit.enqueue(bytes, descriptors);
    }

    pub fn armReceive(actor: *Actor) Error!u64 {
        if (actor.lifecycle != .open) return error.Closing;
        if (actor.receive_active) return error.ReceiveAlreadyActive;
        actor.receive_active = true;
        return actor.token(.receive);
    }

    pub fn beginSend(actor: *Actor, snapshot_value: tx.Snapshot) Error!u64 {
        switch (actor.lifecycle) {
            .open, .draining => {},
            .protocol_error => return error.ProtocolErrorPending,
            .closing => return error.Closing,
        }
        try actor.transmit.begin(snapshot_value);
        return actor.token(.send);
    }

    /// Stops further protocol dispatch while allowing a final wl_display.error
    /// event to be appended to the existing ordered transmit queue.
    pub fn beginProtocolError(actor: *Actor) Error!void {
        if (actor.lifecycle != .open) return error.Closing;
        actor.lifecycle = .protocol_error;
    }

    /// Marks the terminal error as queued. Existing output and the error event
    /// drain in order; the final send completion advances the actor to closing.
    pub fn commitProtocolError(actor: *Actor) Error!void {
        if (actor.lifecycle != .protocol_error) return error.NoProtocolError;
        if (actor.transmit.queuedBytes() == 0) return error.EmptyMessage;
        actor.lifecycle = .draining;
    }

    pub fn beginClose(actor: *Actor) void {
        actor.lifecycle = .closing;
    }

    pub inline fn canDispatch(actor: Actor) bool {
        return actor.lifecycle == .open;
    }

    pub fn cancelToken(actor: Actor) u64 {
        return actor.token(.cancel);
    }

    pub fn canDeinit(actor: Actor) bool {
        return !actor.receive_active and !actor.cancel_active and
            !actor.transmit.sendActive();
    }

    /// Applies a CQE after the reactor has selected this actor's slot. The
    /// generation is checked again so direct callers cannot bypass stale-CQE
    /// protection.
    pub fn complete(actor: *Actor, cqe: linux.io_uring_cqe) Error!Event {
        const token_value = completions.Token.decode(cqe.user_data) catch
            return error.UnexpectedCompletion;
        if (!token_value.belongsTo(actor.slot, actor.generation))
            return error.StaleCompletion;

        return actor.completeRouted(token_value.operation, cqe);
    }

    /// Applies a completion already generation-checked by `reactor.Slots`.
    pub fn completeRouted(
        actor: *Actor,
        operation: completions.Operation,
        cqe: linux.io_uring_cqe,
    ) Error!Event {
        return switch (operation) {
            .receive => actor.completeReceive(cqe),
            .send => actor.completeSend(cqe),
            .cancel => actor.completeCancel(cqe),
            .accept, .accept_cancel => error.UnexpectedCompletion,
        };
    }

    fn completeReceive(actor: *Actor, cqe: linux.io_uring_cqe) Error!Event {
        if (!actor.receive_active) return error.ReceiveNotActive;
        const more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
        actor.receive_active = more;
        if (cqe.res == 0) {
            actor.receive_active = false;
            actor.lifecycle = .closing;
            return .disconnected;
        }
        if (cqe.res < 0) {
            actor.receive_active = false;
            if (actor.lifecycle != .open and cqe.err() == .CANCELED)
                return .receive_stopped;
            if (cqe.err() == .NOBUFS) return .buffers_exhausted;
            actor.lifecycle = .closing;
            return error.IoFailure;
        }
        return .{ .received = .{ .length = @intCast(cqe.res), .more = more } };
    }

    fn completeSend(actor: *Actor, cqe: linux.io_uring_cqe) Error!Event {
        if (cqe.res <= 0) {
            try actor.transmit.failed();
            if (actor.lifecycle == .closing and cqe.err() == .CANCELED)
                return .send_stopped;
            actor.lifecycle = .closing;
            return error.IoFailure;
        }
        const written: usize = @intCast(cqe.res);
        try actor.transmit.complete(written);
        const more_queued = actor.transmit.queuedBytes() > 0;
        if (actor.lifecycle == .draining and !more_queued)
            actor.lifecycle = .closing;
        return .{ .sent = .{
            .length = written,
            .more_queued = more_queued,
        } };
    }

    fn completeCancel(actor: *Actor, cqe: linux.io_uring_cqe) Error!Event {
        if (!actor.cancel_active) return error.CancelNotActive;
        actor.cancel_active = false;
        if (cqe.res < 0 and cqe.err() != .NOENT and cqe.err() != .ALREADY) {
            actor.lifecycle = .closing;
            return error.IoFailure;
        }
        return .cancel_complete;
    }

    fn token(actor: Actor, operation: completions.Operation) u64 {
        return (completions.Token{
            .slot = actor.slot,
            .generation = actor.generation,
            .operation = operation,
        }).encode();
    }
};

test "routes receive and partial send completions through one actor" {
    const allocator = std.testing.allocator;
    var transmit_blocks = try pools.SharedBlocks.init(allocator, 8, 2);
    defer transmit_blocks.deinit(allocator);
    var descriptors = try pools.SharedFds.init(allocator, 4);
    defer descriptors.deinit(allocator);
    var fragment_storage: [64]u8 = undefined;
    var actor = Actor.init(
        3,
        7,
        &fragment_storage,
        &descriptors,
        2,
        &transmit_blocks,
        16,
        2,
    );

    const receive_token = try actor.armReceive();
    const receive_event = try actor.complete(.{
        .user_data = receive_token,
        .res = 12,
        .flags = linux.IORING_CQE_F_MORE,
    });
    try std.testing.expectEqual(@as(usize, 12), receive_event.received.length);
    try std.testing.expect(actor.receive_active);

    try actor.enqueue("abcdef", &.{});
    var descriptor_scratch: [2]linux.fd_t = undefined;
    var control_storage: [64]u8 = undefined;
    const snapshot_value = try actor.transmit.snapshot(&descriptor_scratch, &control_storage);
    const send_token = try actor.beginSend(snapshot_value);
    try actor.enqueue("gh", &.{});

    const concurrent_receive = try actor.complete(.{
        .user_data = receive_token,
        .res = 8,
        .flags = linux.IORING_CQE_F_MORE,
    });
    try std.testing.expectEqual(@as(usize, 8), concurrent_receive.received.length);
    try std.testing.expect(actor.transmit.sendActive());

    const send_event = try actor.complete(.{
        .user_data = send_token,
        .res = 3,
        .flags = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), send_event.sent.length);
    try std.testing.expect(send_event.sent.more_queued);
    try std.testing.expectEqual(@as(usize, 5), actor.transmit.queuedBytes());

    actor.beginClose();
    const stopped = try actor.complete(.{
        .user_data = receive_token,
        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
        .flags = 0,
    });
    try std.testing.expectEqual(Event.receive_stopped, stopped);
    try std.testing.expect(actor.canDeinit());
    actor.deinit();
}

test "terminal protocol errors drain before closing" {
    const allocator = std.testing.allocator;
    var transmit_blocks = try pools.SharedBlocks.init(allocator, 32, 1);
    defer transmit_blocks.deinit(allocator);
    var descriptors = try pools.SharedFds.init(allocator, 1);
    defer descriptors.deinit(allocator);
    var fragment_storage: [32]u8 = undefined;
    var actor = Actor.init(
        1,
        1,
        &fragment_storage,
        &descriptors,
        0,
        &transmit_blocks,
        32,
        0,
    );

    try actor.beginProtocolError();
    try std.testing.expect(!actor.canDispatch());
    try std.testing.expectError(error.Closing, actor.enqueue("ordinary", &.{}));
    try std.testing.expectError(error.Closing, actor.armReceive());
    try std.testing.expectError(error.EmptyMessage, actor.commitProtocolError());

    try actor.transmit.enqueue("terminal", &.{});
    try actor.commitProtocolError();
    try std.testing.expectEqual(Lifecycle.draining, actor.lifecycle);
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control_storage: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot_value = try actor.transmit.snapshot(&descriptor_scratch, &control_storage);
    const send_token = try actor.beginSend(snapshot_value);
    const event = try actor.complete(.{
        .user_data = send_token,
        .res = @intCast(snapshot_value.byteCount()),
        .flags = 0,
    });
    try std.testing.expect(!event.sent.more_queued);
    try std.testing.expectEqual(Lifecycle.closing, actor.lifecycle);
    try std.testing.expect(actor.canDeinit());
    actor.deinit();
}

test "completed cancellation remains requested until receive stops" {
    const allocator = std.testing.allocator;
    var transmit_blocks = try pools.SharedBlocks.init(allocator, 8, 1);
    defer transmit_blocks.deinit(allocator);
    var descriptors = try pools.SharedFds.init(allocator, 1);
    defer descriptors.deinit(allocator);
    var fragment_storage: [8]u8 = undefined;
    var actor = Actor.init(
        1,
        1,
        &fragment_storage,
        &descriptors,
        0,
        &transmit_blocks,
        8,
        0,
    );

    const receive_token = try actor.armReceive();
    actor.beginClose();
    actor.cancel_requested = true;
    actor.cancel_active = true;
    const cancel_event = try actor.complete(.{
        .user_data = actor.cancelToken(),
        .res = 0,
        .flags = 0,
    });
    try std.testing.expectEqual(Event.cancel_complete, cancel_event);
    try std.testing.expect(actor.cancel_requested);
    try std.testing.expect(!actor.cancel_active);
    try std.testing.expect(!actor.canDeinit());

    const receive_event = try actor.complete(.{
        .user_data = receive_token,
        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
        .flags = 0,
    });
    try std.testing.expectEqual(Event.receive_stopped, receive_event);
    try std.testing.expect(actor.canDeinit());
    actor.deinit();
}

test "closing treats a canceled send as orderly teardown" {
    const allocator = std.testing.allocator;
    var transmit_blocks = try pools.SharedBlocks.init(allocator, 8, 1);
    defer transmit_blocks.deinit(allocator);
    var descriptors = try pools.SharedFds.init(allocator, 1);
    defer descriptors.deinit(allocator);
    var fragment_storage: [8]u8 = undefined;
    var actor = Actor.init(
        1,
        1,
        &fragment_storage,
        &descriptors,
        0,
        &transmit_blocks,
        8,
        0,
    );

    try actor.enqueue("blocked", &.{});
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control_storage: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot_value = try actor.transmit.snapshot(&descriptor_scratch, &control_storage);
    const send_token = try actor.beginSend(snapshot_value);
    actor.beginClose();
    try std.testing.expectEqual(Event.send_stopped, try actor.complete(.{
        .user_data = send_token,
        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
        .flags = 0,
    }));
    try std.testing.expectEqual(@as(usize, "blocked".len), actor.transmit.queuedBytes());
    try std.testing.expect(actor.canDeinit());
    actor.deinit();
}

test "rejects stale completion generations" {
    const allocator = std.testing.allocator;
    var transmit_blocks = try pools.SharedBlocks.init(allocator, 8, 1);
    defer transmit_blocks.deinit(allocator);
    var descriptors = try pools.SharedFds.init(allocator, 1);
    defer descriptors.deinit(allocator);
    var fragment_storage: [8]u8 = undefined;
    var actor = Actor.init(
        1,
        2,
        &fragment_storage,
        &descriptors,
        0,
        &transmit_blocks,
        8,
        0,
    );
    const stale = (completions.Token{
        .slot = 1,
        .generation = 1,
        .operation = .receive,
    }).encode();
    try std.testing.expectError(error.StaleCompletion, actor.complete(.{
        .user_data = stale,
        .res = 1,
        .flags = 0,
    }));
}
