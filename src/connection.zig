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

/// Top-level connection phase: the superstate of `State.Phase`.
pub const Lifecycle = enum(u8) {
    open,
    protocol_error,
    draining,
    closing,
};

/// Connection statechart with two orthogonal regions in one byte:
///
///     phase:   open ─▶ protocol_error ─▶ draining ─▶ closing
///              (EOF, I/O failure, or close from any phase enters closing)
///              closing ─▶ canceling ─▶ canceled   (substates, never left)
///     receive: idle ⇄ active, armed only while open
///
/// Send activity is a third region owned by `tx.Queue`. Every representable
/// state is reachable, so impossible flag combinations cannot be constructed.
pub const State = packed struct(u8) {
    phase: Phase = .open,
    receiving: bool = false,
    _padding: u4 = 0,

    pub const Phase = enum(u3) {
        open,
        protocol_error,
        draining,
        /// Closing substates track the descriptor-wide cancel SQE.
        closing,
        canceling,
        canceled,
    };

    pub const Input = enum {
        arm_receive,
        begin_protocol_error,
        commit_protocol_error,
        begin_close,
        request_cancel,
        /// Multishot receive delivered data and remains armed.
        receive_continues,
        /// Receive terminated without changing the phase (stopped or ENOBUFS).
        receive_stops,
        /// Receive terminated by EOF or failure; the connection closes.
        receive_closes,
        /// The final queued byte was sent.
        send_drained,
        send_fails,
        cancel_completes,
    };

    pub const TransitionError = error{
        Closing,
        ReceiveAlreadyActive,
        ReceiveNotActive,
        NoProtocolError,
        CancelAlreadyActive,
        CancelNotActive,
    };

    /// The transition table. `input` is comptime so each call site folds to
    /// the same field tests and stores as handwritten flag updates.
    pub inline fn step(state: State, comptime input: Input) TransitionError!State {
        var next = state;
        switch (input) {
            .arm_receive => {
                if (state.phase != .open) return error.Closing;
                if (state.receiving) return error.ReceiveAlreadyActive;
                next.receiving = true;
            },
            .begin_protocol_error => {
                if (state.phase != .open) return error.Closing;
                next.phase = .protocol_error;
            },
            .commit_protocol_error => {
                if (state.phase != .protocol_error) return error.NoProtocolError;
                next.phase = .draining;
            },
            .begin_close => next.phase = state.closedPhase(),
            .request_cancel => switch (state.phase) {
                .canceling, .canceled => return error.CancelAlreadyActive,
                else => next.phase = .canceling,
            },
            .receive_continues => {
                if (!state.receiving) return error.ReceiveNotActive;
            },
            .receive_stops => {
                if (!state.receiving) return error.ReceiveNotActive;
                next.receiving = false;
            },
            .receive_closes => {
                if (!state.receiving) return error.ReceiveNotActive;
                next.receiving = false;
                next.phase = state.closedPhase();
            },
            .send_drained => if (state.phase == .draining) {
                next.phase = .closing;
            },
            .send_fails => next.phase = state.closedPhase(),
            .cancel_completes => {
                if (state.phase != .canceling) return error.CancelNotActive;
                next.phase = .canceled;
            },
        }
        return next;
    }

    /// Entering the closing superstate preserves an existing closing substate.
    inline fn closedPhase(state: State) Phase {
        return switch (state.phase) {
            .open, .protocol_error, .draining => .closing,
            else => state.phase,
        };
    }

    pub inline fn lifecycle(state: State) Lifecycle {
        return switch (state.phase) {
            .open => .open,
            .protocol_error => .protocol_error,
            .draining => .draining,
            .closing, .canceling, .canceled => .closing,
        };
    }

    pub inline fn cancelRequested(state: State) bool {
        return state.phase == .canceling or state.phase == .canceled;
    }

    pub inline fn cancelActive(state: State) bool {
        return state.phase == .canceling;
    }
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
    state: State = .{},

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
        if (actor.state.phase != .open) return error.Closing;
        return actor.transmit.enqueue(bytes, descriptors);
    }

    pub inline fn lifecycle(actor: Actor) Lifecycle {
        return actor.state.lifecycle();
    }

    pub inline fn receiveActive(actor: Actor) bool {
        return actor.state.receiving;
    }

    pub inline fn cancelRequested(actor: Actor) bool {
        return actor.state.cancelRequested();
    }

    pub inline fn cancelActive(actor: Actor) bool {
        return actor.state.cancelActive();
    }

    pub fn armReceive(actor: *Actor) Error!u64 {
        actor.state = try actor.state.step(.arm_receive);
        return actor.token(.receive);
    }

    pub fn beginSend(actor: *Actor, snapshot_value: tx.Snapshot) Error!u64 {
        switch (actor.lifecycle()) {
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
        actor.state = try actor.state.step(.begin_protocol_error);
    }

    /// Marks the terminal error as queued. Existing output and the error event
    /// drain in order; the final send completion advances the actor to closing.
    pub fn commitProtocolError(actor: *Actor) Error!void {
        const next = try actor.state.step(.commit_protocol_error);
        if (actor.transmit.queuedBytes() == 0) return error.EmptyMessage;
        actor.state = next;
    }

    pub fn beginClose(actor: *Actor) void {
        actor.state = actor.state.step(.begin_close) catch unreachable;
    }

    /// Enters closing and records an in-flight descriptor-wide cancel SQE.
    /// Callers that fail to queue the SQE restore their prior `state`.
    pub fn requestCancel(actor: *Actor) Error!void {
        actor.state = try actor.state.step(.request_cancel);
    }

    pub inline fn canDispatch(actor: Actor) bool {
        return actor.state.phase == .open;
    }

    pub fn cancelToken(actor: Actor) u64 {
        return actor.token(.cancel);
    }

    pub fn canDeinit(actor: Actor) bool {
        return !actor.state.receiving and !actor.state.cancelActive() and
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
        const more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
        if (cqe.res > 0) {
            actor.state = if (more)
                try actor.state.step(.receive_continues)
            else
                try actor.state.step(.receive_stops);
            return .{ .received = .{ .length = @intCast(cqe.res), .more = more } };
        }
        if (cqe.res == 0) {
            actor.state = try actor.state.step(.receive_closes);
            return .disconnected;
        }
        if (actor.state.phase != .open and cqe.err() == .CANCELED) {
            actor.state = try actor.state.step(.receive_stops);
            return .receive_stopped;
        }
        if (cqe.err() == .NOBUFS) {
            actor.state = try actor.state.step(.receive_stops);
            return .buffers_exhausted;
        }
        actor.state = try actor.state.step(.receive_closes);
        return error.IoFailure;
    }

    fn completeSend(actor: *Actor, cqe: linux.io_uring_cqe) Error!Event {
        if (cqe.res <= 0) {
            try actor.transmit.failed();
            if (actor.lifecycle() == .closing and cqe.err() == .CANCELED)
                return .send_stopped;
            actor.state = actor.state.step(.send_fails) catch unreachable;
            return error.IoFailure;
        }
        const written: usize = @intCast(cqe.res);
        try actor.transmit.complete(written);
        const more_queued = actor.transmit.queuedBytes() > 0;
        if (!more_queued) actor.state = actor.state.step(.send_drained) catch unreachable;
        return .{ .sent = .{
            .length = written,
            .more_queued = more_queued,
        } };
    }

    fn completeCancel(actor: *Actor, cqe: linux.io_uring_cqe) Error!Event {
        actor.state = try actor.state.step(.cancel_completes);
        if (cqe.res < 0 and cqe.err() != .NOENT and cqe.err() != .ALREADY)
            return error.IoFailure;
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

test "statechart is fully reachable, closing is absorbing, and teardown always quiesces" {
    const statechart = @import("statechart.zig");
    const all_inputs = comptime std.enums.values(State.Input);
    const teardown_inputs = [_]State.Input{
        .begin_close, .request_cancel, .receive_stops, .receive_closes, .cancel_completes,
    };

    var reachable_storage: [256]State = undefined;
    const reachable = statechart.members(
        State,
        &statechart.reach(State, all_inputs, .{}),
        &reachable_storage,
    );
    // Every representable phase/receive combination is reachable.
    try std.testing.expectEqual(std.enums.values(State.Phase).len * 2, reachable.len);

    for (reachable) |state| {
        var next: [all_inputs.len]State = undefined;
        for (statechart.successors(State, all_inputs, state, &next)) |successor| {
            if (state.lifecycle() == .closing)
                try std.testing.expectEqual(Lifecycle.closing, successor.lifecycle());
            if (!state.receiving and successor.receiving)
                try std.testing.expectEqual(State.Phase.open, state.phase);
        }

        // Liveness: teardown inputs alone reach a deinit-safe state.
        var teardown_storage: [256]State = undefined;
        const teardown = statechart.members(
            State,
            &statechart.reach(State, &teardown_inputs, state),
            &teardown_storage,
        );
        const quiesces = for (teardown) |candidate| {
            if (candidate.lifecycle() == .closing and
                !candidate.receiving and !candidate.cancelActive()) break true;
        } else false;
        try std.testing.expect(quiesces);
    }
}

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
    try std.testing.expect(actor.receiveActive());

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
    try std.testing.expectEqual(Lifecycle.draining, actor.lifecycle());
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
    try std.testing.expectEqual(Lifecycle.closing, actor.lifecycle());
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
    try actor.requestCancel();
    const cancel_event = try actor.complete(.{
        .user_data = actor.cancelToken(),
        .res = 0,
        .flags = 0,
    });
    try std.testing.expectEqual(Event.cancel_complete, cancel_event);
    try std.testing.expect(actor.cancelRequested());
    try std.testing.expect(!actor.cancelActive());
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
