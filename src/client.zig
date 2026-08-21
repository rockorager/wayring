//! Allocation-free core client operations over generated protocol codecs.

const std = @import("std");
const ancillary = @import("ancillary.zig");
const connection_state = @import("connection.zig");
const io_uring = @import("io_uring.zig");
const metadata = @import("metadata.zig");
const objects = @import("objects.zig");
const tx = @import("tx.zig");
const wire = @import("wire.zig");

/// Application state attached to a generated typed `new_id` constructor.
pub const NewObjectContext = struct {
    context: ?*anyopaque = null,
};

/// Metadata and application state for a typed `new_id` whose interface is
/// declared in another generated protocol module.
pub const TypedNewObject = struct {
    interface: *const metadata.Interface,
    context: ?*anyopaque = null,
};

/// Interface, negotiated version, and application state for an untyped
/// (dynamic) generated `new_id` constructor.
pub const NewObject = struct {
    interface: *const metadata.Interface,
    version: u32,
    context: ?*anyopaque = null,
};

/// Encodes an arbitrary generated request and applies destructor lifecycle only
/// after the complete frame is committed to the transmit queue.
pub fn sendRequest(
    comptime Interface: type,
    client_objects: *objects.ClientObjects,
    queue: *tx.Queue,
    handle: objects.Handle,
    request: Interface.Request,
) !void {
    const object = client_objects.namespace.resolve(handle) orelse
        return error.StaleHandle;
    if (object.interface != &Interface.info) return error.WrongInterface;
    const opcode: u16 = @intCast(@intFromEnum(std.meta.activeTag(request)));
    const message = try object.interface.request(opcode, object.version);
    if (@hasDecl(Interface, "validateRequestObjects"))
        try Interface.validateRequestObjects(&client_objects.namespace, request);
    try Interface.encodeRequest(queue, handle.id, request);
    if (message.destructor) retire(client_objects, handle);
}

/// Decodes an arbitrary generated event and retires its object when the event
/// metadata marks it as a destructor. The numeric ID remains held until the
/// later wl_display.delete_id event is applied by `Core.decodeDisplayEvent`.
pub fn decodeEvent(
    comptime Interface: type,
    client_objects: *objects.ClientObjects,
    handle: objects.Handle,
    message: wire.Message,
    fds: *ancillary.FdQueue,
) !Interface.Event {
    if (message.header.object_id != handle.id) return error.WrongObject;
    const object = client_objects.namespace.resolve(handle) orelse
        return error.StaleHandle;
    if (object.interface != &Interface.info) return error.WrongInterface;
    const metadata_message = try object.interface.event(
        message.header.opcode,
        object.version,
    );
    const event = if (@hasDecl(Interface, "decodeEventObjects"))
        try Interface.decodeEventObjects(&client_objects.namespace, message, fds)
    else
        try Interface.decodeEvent(message, fds);
    if (metadata_message.destructor) retire(client_objects, handle);
    return event;
}

fn retire(client_objects: *objects.ClientObjects, handle: objects.Handle) void {
    _ = if (handle.id < objects.server_id_start)
        client_objects.retireLocal(handle) catch unreachable
    else
        client_objects.removePeer(handle) catch unreachable;
}

/// Owns the cold-path association between one reactor peer and its client-side
/// object namespace. CQE routing, completion handling, dispatch, batching, and
/// submission remain explicit so the reactor can share a caller-owned ring.
pub fn Connection(comptime protocol: type) type {
    return struct {
        const Self = @This();

        reactor: *io_uring.Reactor,
        peer: io_uring.Peer,
        objects: objects.ClientObjects,

        pub const ObjectConfig = struct {
            max_objects: usize,
            max_client_ids: usize,
            display_context: ?*anyopaque = null,
        };

        /// Consumes `socket_fd`, initializes wl_display, and queues the initial
        /// receive without submitting it. Setup failure closes the descriptor
        /// and recycles every partially initialized resource.
        pub fn attach(
            allocator: std.mem.Allocator,
            reactor: *io_uring.Reactor,
            socket_fd: std.os.linux.fd_t,
            actor_config: io_uring.ActorConfig,
            object_config: ObjectConfig,
        ) !Self {
            const peer = try reactor.attach(socket_fd, actor_config);
            errdefer reactor.destroyPeer(peer) catch unreachable;
            var client_objects = try objects.ClientObjects.init(
                allocator,
                object_config.max_objects,
                object_config.max_client_ids,
                &protocol.wl_display.info,
                object_config.display_context,
            );
            errdefer client_objects.deinit(allocator);
            try reactor.prepareReceive(peer);
            return .{
                .reactor = reactor,
                .peer = peer,
                .objects = client_objects,
            };
        }

        pub inline fn actor(connection: *Self) !*connection_state.Actor {
            return connection.reactor.getActor(connection.peer);
        }

        pub inline fn receiver(connection: *Self) !*io_uring.Receiver {
            return connection.reactor.getReceiver(connection.peer);
        }

        /// Queues asynchronous socket-I/O cancellation without submitting it.
        pub inline fn prepareClose(connection: *Self) !bool {
            return connection.reactor.prepareClose(connection.peer);
        }

        /// Closes and recycles a fully quiesced peer, then releases object
        /// storage. I/O cancellation completions remain caller-run.
        pub fn deinit(connection: *Self, allocator: std.mem.Allocator) !void {
            const peer_actor = try connection.actor();
            if (!peer_actor.canDeinit()) return error.ActorBusy;
            try connection.reactor.destroyPeer(connection.peer);
            connection.objects.deinit(allocator);
            connection.* = undefined;
        }
    };
}

/// Instantiates core operations from a scanner-generated module containing
/// wl_display, wl_registry, and wl_callback. The generated types remain the
/// source of truth; this layer owns only object lifecycle and side effects.
pub fn Core(comptime protocol: type) type {
    return struct {
        pub const Display = protocol.wl_display;
        pub const Registry = protocol.wl_registry;
        pub const Callback = protocol.wl_callback;

        pub const Error = objects.ClientObjectsError ||
            Display.EncodeError || Display.DecodeError ||
            Registry.EncodeError || Registry.DecodeError ||
            Callback.DecodeError || metadata.Error || error{
            WrongInterface,
            WrongObject,
        };

        pub const EventResult = union(enum) {
            dispatched: usize,
            terminal: struct {
                dispatched: usize,
                object_id: ?u32,
                cause: anyerror,
            },
        };

        /// Dispatches complete events and closes on framing, object lookup,
        /// decoding, handler, or server protocol errors. A wl_display.error is
        /// delivered to the handler, then stops the current concatenated batch.
        pub fn dispatchEvents(
            actor: *connection_state.Actor,
            namespace: anytype,
            bytes: *[]const u8,
            context: anytype,
        ) EventResult {
            if (!actor.canDispatch()) return .{ .dispatched = 0 };
            var count: usize = 0;
            while (true) {
                const message = actor.nextMessage(bytes) catch |cause|
                    return terminalEvent(actor, count, null, cause);
                const complete = message orelse return .{ .dispatched = count };
                const target = namespace.event(
                    complete.header.object_id,
                    complete.header.opcode,
                ) catch |cause| return terminalEvent(
                    actor,
                    count,
                    complete.header.object_id,
                    cause,
                );
                const server_error = target.object.interface == &Display.info and
                    complete.header.opcode == @intFromEnum(
                        std.meta.Tag(Display.Event).@"error",
                    );
                const control = context.event(
                    target,
                    complete,
                    &actor.received_fds,
                ) catch |cause| return terminalEvent(
                    actor,
                    count,
                    complete.header.object_id,
                    cause,
                );
                count += 1;
                if (server_error)
                    return terminalEvent(actor, count, complete.header.object_id, error.ServerProtocolError);
                if (control == .stop) return .{ .dispatched = count };
            }
        }

        /// Selected-buffer counterpart to `dispatchEvents`. The kernel buffer
        /// is returned exactly once; CQE routing and close cancellation remain
        /// explicit at the caller boundary.
        pub inline fn receivedEvents(
            actor: *connection_state.Actor,
            namespace: anytype,
            receiver: anytype,
            completion: std.os.linux.io_uring_cqe,
            context: anytype,
        ) !EventResult {
            const received = receiver.decodeCompletion(completion) catch |cause|
                return terminalEvent(actor, 0, null, cause);
            _ = actor.ingestControl(received.control) catch |cause| {
                receiver.release(received) catch {};
                return terminalEvent(actor, 0, null, cause);
            };
            var payload = received.payload;
            const result = dispatchEvents(actor, namespace, &payload, context);
            try receiver.release(received);
            return result;
        }

        fn terminalEvent(
            actor: *connection_state.Actor,
            dispatched: usize,
            object_id: ?u32,
            cause: anyerror,
        ) EventResult {
            actor.beginClose();
            return .{ .terminal = .{
                .dispatched = dispatched,
                .object_id = object_id,
                .cause = cause,
            } };
        }

        pub fn sync(
            client_objects: *objects.ClientObjects,
            queue: *tx.Queue,
            context: ?*anyopaque,
        ) Error!objects.Handle {
            const callback = try client_objects.createLocal(&Callback.info, 1, context);
            errdefer _ = client_objects.cancelLocal(callback) catch unreachable;
            try Display.encodeRequest(queue, objects.display_id, .{
                .sync = .{ .callback = callback.id },
            });
            return callback;
        }

        pub fn getRegistry(
            client_objects: *objects.ClientObjects,
            queue: *tx.Queue,
            context: ?*anyopaque,
        ) Error!objects.Handle {
            const registry = try client_objects.createLocal(&Registry.info, 1, context);
            errdefer _ = client_objects.cancelLocal(registry) catch unreachable;
            try Display.encodeRequest(queue, objects.display_id, .{
                .get_registry = .{ .registry = registry.id },
            });
            return registry;
        }

        pub fn bind(
            client_objects: *objects.ClientObjects,
            queue: *tx.Queue,
            registry: objects.Handle,
            global_name: u32,
            interface: *const metadata.Interface,
            version: u32,
            context: ?*anyopaque,
        ) Error!objects.Handle {
            try requireObject(client_objects, registry, &Registry.info);
            const object = try client_objects.createLocal(interface, version, context);
            errdefer _ = client_objects.cancelLocal(object) catch unreachable;
            try Registry.encodeRequest(queue, registry.id, .{
                .bind = .{
                    .name = global_name,
                    .id = .{
                        .interface = interface.name,
                        .version = version,
                        .id = object.id,
                    },
                },
            });
            return object;
        }

        pub fn decodeDisplayEvent(
            client_objects: *objects.ClientObjects,
            message: wire.Message,
            fds: *ancillary.FdQueue,
        ) Error!Display.Event {
            try requireMessage(client_objects, message, &Display.info);
            const event = if (@hasDecl(Display, "decodeEventObjects"))
                try Display.decodeEventObjects(&client_objects.namespace, message, fds)
            else
                try Display.decodeEvent(message, fds);
            switch (event) {
                .delete_id => |deleted| try client_objects.deleted(deleted.id),
                .@"error" => {},
            }
            return event;
        }

        pub fn decodeRegistryEvent(
            client_objects: *objects.ClientObjects,
            registry: objects.Handle,
            message: wire.Message,
            fds: *ancillary.FdQueue,
        ) Error!Registry.Event {
            if (message.header.object_id != registry.id) return error.WrongObject;
            try requireObject(client_objects, registry, &Registry.info);
            try requireMessage(client_objects, message, &Registry.info);
            return Registry.decodeEvent(message, fds);
        }

        pub fn decodeCallbackEvent(
            client_objects: *objects.ClientObjects,
            callback: objects.Handle,
            message: wire.Message,
            fds: *ancillary.FdQueue,
        ) Error!Callback.Event {
            return decodeEvent(Callback, client_objects, callback, message, fds);
        }

        fn requireObject(
            client_objects: *objects.ClientObjects,
            handle: objects.Handle,
            interface: *const metadata.Interface,
        ) Error!void {
            const object = client_objects.namespace.resolve(handle) orelse
                return error.StaleHandle;
            if (object.interface != interface) return error.WrongInterface;
        }

        fn requireMessage(
            client_objects: *objects.ClientObjects,
            message: wire.Message,
            interface: *const metadata.Interface,
        ) Error!void {
            const dispatch = try client_objects.namespace.event(
                message.header.object_id,
                message.header.opcode,
            );
            if (dispatch.object.interface != interface) return error.WrongInterface;
        }
    };
}
