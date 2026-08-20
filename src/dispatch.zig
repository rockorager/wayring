//! Compile-time-specialized framed object dispatch.

const ancillary = @import("ancillary.zig");
const std = @import("std");
const connection = @import("connection.zig");
const objects = @import("objects.zig");
const wire = @import("wire.zig");

pub const Control = enum {
    continue_dispatch,
    stop,
};

pub fn requests(
    actor: *connection.Actor,
    namespace: anytype,
    bytes: *[]const u8,
    context: anytype,
) !usize {
    if (!actor.canDispatch()) return 0;
    var count: usize = 0;
    while (try actor.nextMessage(bytes)) |message| {
        const target = try namespace.request(
            message.header.object_id,
            message.header.opcode,
        );
        const control = try context.request(target, message, &actor.received_fds);
        count += 1;
        if (control == .stop) break;
    }
    return count;
}

pub fn events(
    actor: *connection.Actor,
    namespace: anytype,
    bytes: *[]const u8,
    context: anytype,
) !usize {
    if (!actor.canDispatch()) return 0;
    var count: usize = 0;
    while (try actor.nextMessage(bytes)) |message| {
        const target = try namespace.event(
            message.header.object_id,
            message.header.opcode,
        );
        const control = try context.event(target, message, &actor.received_fds);
        count += 1;
        if (control == .stop) break;
    }
    return count;
}

/// Decodes one selected-buffer receive completion, ingests its descriptor lane,
/// dispatches every complete request, and returns the kernel buffer exactly once.
/// Completion routing and receive rearming remain explicit in the reactor loop.
pub inline fn receivedRequests(
    actor: *connection.Actor,
    namespace: anytype,
    receiver: anytype,
    completion: std.os.linux.io_uring_cqe,
    context: anytype,
) !usize {
    const received = try receiver.decodeCompletion(completion);
    _ = actor.ingestControl(received.control) catch |err| {
        receiver.release(received) catch {};
        return err;
    };
    var payload = received.payload;
    const count = requests(actor, namespace, &payload, context) catch |err| {
        receiver.release(received) catch {};
        return err;
    };
    try receiver.release(received);
    return count;
}

/// Client-side counterpart to `receivedRequests`.
pub inline fn receivedEvents(
    actor: *connection.Actor,
    namespace: anytype,
    receiver: anytype,
    completion: std.os.linux.io_uring_cqe,
    context: anytype,
) !usize {
    const received = try receiver.decodeCompletion(completion);
    _ = actor.ingestControl(received.control) catch |err| {
        receiver.release(received) catch {};
        return err;
    };
    var payload = received.payload;
    const count = events(actor, namespace, &payload, context) catch |err| {
        receiver.release(received) catch {};
        return err;
    };
    try receiver.release(received);
    return count;
}

test "dispatches concatenated frames after object metadata validation" {
    const pools = @import("pool.zig");

    const info: @import("metadata.zig").Interface = .{
        .name = "sample_v1",
        .version = 1,
        .requests = &.{.{ .since = 1 }},
        .events = &.{.{ .since = 1 }},
    };
    var namespace = try objects.Namespace.init(std.testing.allocator, 1);
    defer namespace.deinit(std.testing.allocator);
    _ = try namespace.insert(4, &info, 1, null);
    var fd_pool = try pools.SharedFds.init(std.testing.allocator, 1);
    defer fd_pool.deinit(std.testing.allocator);
    var transmit_blocks = try pools.SharedBlocks.init(std.testing.allocator, 64, 1);
    defer transmit_blocks.deinit(std.testing.allocator);
    var fragment_storage: [64]u8 = undefined;
    var actor = connection.Actor.init(
        0,
        1,
        &fragment_storage,
        &fd_pool,
        0,
        &transmit_blocks,
        64,
        0,
    );
    defer actor.deinit();

    var storage: [24]u8 = undefined;
    try frame(storage[0..12], 4, 0, 11);
    try frame(storage[12..24], 4, 0, 13);
    var bytes: []const u8 = &storage;
    var handler: TestHandler = .{};
    try std.testing.expectEqual(
        @as(usize, 2),
        try requests(&actor, &namespace, &bytes, &handler),
    );
    try std.testing.expectEqual(@as(u32, 24), handler.total);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);

    try frame(storage[0..12], 4, 0, 17);
    try frame(storage[12..24], 4, 0, 19);
    bytes = &storage;
    var terminal_handler: TerminalHandler = .{ .actor = &actor };
    try std.testing.expectEqual(
        @as(usize, 1),
        try requests(&actor, &namespace, &bytes, &terminal_handler),
    );
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    actor.beginClose();
}

const TestHandler = struct {
    total: u32 = 0,

    fn request(
        handler: *TestHandler,
        _: objects.Dispatch,
        message: wire.Message,
        _: *ancillary.FdQueue,
    ) !Control {
        var arguments = message.arguments();
        handler.total += try arguments.uint();
        try arguments.finish();
        return .continue_dispatch;
    }
};

const TerminalHandler = struct {
    actor: *connection.Actor,

    fn request(
        handler: *TerminalHandler,
        _: objects.Dispatch,
        message: wire.Message,
        _: *ancillary.FdQueue,
    ) !Control {
        var arguments = message.arguments();
        _ = try arguments.uint();
        try arguments.finish();
        try handler.actor.beginProtocolError();
        return .stop;
    }
};

fn frame(storage: []u8, object_id: u32, opcode: u16, value: u32) !void {
    try (wire.Header{
        .object_id = object_id,
        .opcode = opcode,
        .size = 12,
    }).encode(storage[0..wire.header_len]);
    std.mem.writeInt(
        u32,
        storage[wire.header_len..12],
        value,
        @import("builtin").cpu.arch.endian(),
    );
}
