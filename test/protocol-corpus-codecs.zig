const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("corpus_protocol");

const linux = std.os.linux;

// Kept mutable so the compiler analyzes the calls without executing them. The
// values are deliberately undefined: this test checks every generated helper
// body at compile time, while the focused protocol tests exercise real data.
var execute_helpers = false;

test "all generated helpers compile" {
    @setEvalBranchQuota(1_000_000);
    inline for (comptime std.meta.declarations(protocol)) |declaration| {
        const value = @field(protocol, declaration.name);
        if (@TypeOf(value) == type and @hasDecl(value, "info")) {
            try instantiateHelpers(value);
        }
    }
}

test "all generated messages round trip" {
    @setEvalBranchQuota(1_000_000);
    var blocks = try wayring.pool.SharedBlocks.init(
        std.testing.allocator,
        wayring.wire.max_message_len,
        1,
    );
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 8);
    defer descriptors.deinit(std.testing.allocator);

    inline for (comptime std.meta.declarations(protocol)) |declaration| {
        const value = @field(protocol, declaration.name);
        if (@TypeOf(value) == type and @hasDecl(value, "info")) {
            try roundTripMessages(value, &blocks, &descriptors);
        }
    }
}

fn instantiateHelpers(comptime Interface: type) !void {
    if (!execute_helpers) return;

    const queue: *wayring.tx.Queue = undefined;
    const message: wayring.wire.Message = undefined;
    const fds: *wayring.ancillary.FdQueue = undefined;

    inline for (@typeInfo(Interface.Request).@"union".fields) |field| {
        const request = @unionInit(
            Interface.Request,
            field.name,
            defaultValue(field.type),
        );
        _ = try Interface.requestSize(request);
        try Interface.encodeRequest(queue, 1, request);
    }
    _ = try Interface.decodeRequest(message, fds);
    if (@hasDecl(Interface, "decodeRequestObjects")) {
        const namespace: *wayring.objects.Namespace = undefined;
        _ = try Interface.decodeRequestObjects(namespace, message, fds);
    }

    inline for (@typeInfo(Interface.Event).@"union".fields) |field| {
        const event = @unionInit(
            Interface.Event,
            field.name,
            defaultValue(field.type),
        );
        _ = try Interface.eventSize(event);
        try Interface.encodeEvent(queue, 1, event);
    }
    _ = try Interface.decodeEvent(message, fds);
    if (@hasDecl(Interface, "decodeEventObjects")) {
        const namespace: *wayring.objects.Namespace = undefined;
        _ = try Interface.decodeEventObjects(namespace, message, fds);
    }

    const client_objects: *wayring.objects.ClientObjects = undefined;
    const server_objects: *wayring.objects.ServerObjects = undefined;
    const parent = defaultValue(wayring.objects.Handle);
    inline for (comptime std.meta.declarations(Interface)) |declaration| {
        if (comptime std.mem.startsWith(u8, declaration.name, "Constructor_")) {
            const suffix = declaration.name["Constructor_".len..];
            _ = try @field(Interface, "construct_" ++ suffix)(
                client_objects,
                queue,
                parent,
                defaultValue(@field(Interface, declaration.name)),
            );
        } else if (comptime std.mem.startsWith(u8, declaration.name, "NewObjects_")) {
            const suffix = declaration.name["NewObjects_".len..];
            _ = try @field(Interface, "admit_" ++ suffix)(
                server_objects,
                parent,
                defaultValue(@field(Interface, "Request_" ++ suffix)),
                defaultValue(@field(Interface, declaration.name)),
            );
        } else if (comptime std.mem.startsWith(u8, declaration.name, "EventConstructor_")) {
            const suffix = declaration.name["EventConstructor_".len..];
            _ = try @field(Interface, "construct_event_" ++ suffix)(
                protocol,
                server_objects,
                queue,
                parent,
                defaultValue(@field(Interface, declaration.name)),
            );
        } else if (comptime std.mem.startsWith(u8, declaration.name, "EventNewObjects_")) {
            const suffix = declaration.name["EventNewObjects_".len..];
            _ = try @field(Interface, "admit_event_" ++ suffix)(
                client_objects,
                parent,
                defaultValue(@field(Interface, "Event_" ++ suffix)),
                defaultValue(@field(Interface, declaration.name)),
            );
        }
    }
}

fn roundTripMessages(
    comptime Interface: type,
    blocks: *wayring.pool.SharedBlocks,
    descriptors: *wayring.pool.SharedFds,
) !void {
    if (comptime Interface.info.requests.len != 0) {
        inline for (@typeInfo(Interface.Request).@"union".fields, 0..) |field, opcode| {
            const original = try createDescriptor();
            var original_owned = true;
            defer if (original_owned) {
                _ = linux.close(original);
            };
            const request = @unionInit(
                Interface.Request,
                field.name,
                runtimeValue(field.type, original),
            );
            var queue = wayring.tx.Queue.init(
                blocks,
                wayring.wire.max_message_len,
                descriptors,
                2,
            );
            defer queue.deinit();
            const expected_size = try Interface.requestSize(request);
            try Interface.encodeRequest(&queue, 1, request);
            if (queue.queuedDescriptors() != 0) original_owned = false;
            var message = try snapshotMessage(&queue, descriptors);
            defer message.fds.deinit();
            try std.testing.expectEqual(@as(u16, @intCast(opcode)), message.value.header.opcode);
            try std.testing.expectEqual(expected_size, message.value.header.size);
            const decoded = try Interface.decodeRequest(message.value, &message.fds);
            try std.testing.expectEqual(
                @field(std.meta.Tag(Interface.Request), field.name),
                std.meta.activeTag(decoded),
            );
            try std.testing.expectEqual(@as(usize, 0), message.fds.len());
            message.closeDescriptors();
            try consumeSnapshot(&queue, message.byte_count);
        }
    }

    if (comptime Interface.info.events.len != 0) {
        inline for (@typeInfo(Interface.Event).@"union".fields, 0..) |field, opcode| {
            const original = try createDescriptor();
            var original_owned = true;
            defer if (original_owned) {
                _ = linux.close(original);
            };
            const event = @unionInit(
                Interface.Event,
                field.name,
                runtimeValue(field.type, original),
            );
            var queue = wayring.tx.Queue.init(
                blocks,
                wayring.wire.max_message_len,
                descriptors,
                2,
            );
            defer queue.deinit();
            const expected_size = try Interface.eventSize(event);
            try Interface.encodeEvent(&queue, 1, event);
            if (queue.queuedDescriptors() != 0) original_owned = false;
            var message = try snapshotMessage(&queue, descriptors);
            defer message.fds.deinit();
            try std.testing.expectEqual(@as(u16, @intCast(opcode)), message.value.header.opcode);
            try std.testing.expectEqual(expected_size, message.value.header.size);
            const decoded = try Interface.decodeEvent(message.value, &message.fds);
            try std.testing.expectEqual(
                @field(std.meta.Tag(Interface.Event), field.name),
                std.meta.activeTag(decoded),
            );
            try std.testing.expectEqual(@as(usize, 0), message.fds.len());
            message.closeDescriptors();
            try consumeSnapshot(&queue, message.byte_count);
        }
    }
}

const SnapshotMessage = struct {
    value: wayring.wire.Message,
    fds: wayring.ancillary.FdQueue,
    received: [2]linux.fd_t,
    received_count: usize,
    byte_count: usize,

    fn closeDescriptors(message: SnapshotMessage) void {
        for (message.received[0..message.received_count]) |fd| _ = linux.close(fd);
    }
};

fn snapshotMessage(
    queue: *wayring.tx.Queue,
    descriptors: *wayring.pool.SharedFds,
) !SnapshotMessage {
    var descriptor_scratch: [2]linux.fd_t = undefined;
    var control: [128]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    var result: SnapshotMessage = .{
        .value = (try wayring.wire.Message.decode(snapshot.first)) orelse
            return error.IncompleteMessage,
        .fds = wayring.ancillary.FdQueue.init(descriptors, 2),
        .received = undefined,
        .received_count = 0,
        .byte_count = snapshot.byteCount(),
    };
    errdefer result.fds.deinit();
    for (descriptor_scratch[0..snapshot.descriptor_count]) |fd| {
        const duplicate = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
        try expectSuccess(duplicate);
        const received: linux.fd_t = @intCast(duplicate);
        result.fds.append(received) catch |err| {
            _ = linux.close(received);
            return err;
        };
        result.received[result.received_count] = received;
        result.received_count += 1;
    }
    return result;
}

fn consumeSnapshot(queue: *wayring.tx.Queue, byte_count: usize) !void {
    var descriptor_scratch: [2]linux.fd_t = undefined;
    var control: [128]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    try queue.begin(snapshot);
    try queue.complete(byte_count);
}

fn createDescriptor() !linux.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try expectSuccess(result);
    return @intCast(result);
}

fn expectSuccess(result: usize) !void {
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return std.posix.unexpectedErrno(errno);
}

fn defaultValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .int => 0,
        .optional => null,
        .pointer => |info| switch (info.size) {
            .slice => &.{},
            else => undefined,
        },
        .@"struct" => |info| value: {
            var result: T = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = defaultValue(field.type);
            }
            break :value result;
        },
        else => @compileError("unsupported protocol value type " ++ @typeName(T)),
    };
}

fn runtimeValue(comptime T: type, descriptor: linux.fd_t) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .int => @intCast(descriptor),
        .optional => null,
        .pointer => |info| switch (info.size) {
            .slice => &.{1},
            else => undefined,
        },
        .@"struct" => |info| value: {
            var result: T = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = runtimeValue(field.type, descriptor);
            }
            break :value result;
        },
        else => @compileError("unsupported protocol value type " ++ @typeName(T)),
    };
}
