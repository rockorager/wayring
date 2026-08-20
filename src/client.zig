//! Allocation-free core client operations over generated protocol codecs.

const std = @import("std");
const ancillary = @import("ancillary.zig");
const connection_state = @import("connection.zig");
const io_uring = @import("io_uring.zig");
const metadata = @import("metadata.zig");
const objects = @import("objects.zig");
const tx = @import("tx.zig");
const wire = @import("wire.zig");

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
    const event = try Interface.decodeEvent(message, fds);
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

        /// Queues asynchronous receive cancellation without submitting it.
        pub inline fn prepareClose(connection: *Self) !bool {
            return connection.reactor.prepareClose(connection.peer);
        }

        /// Closes and recycles a fully quiesced peer, then releases object
        /// storage. Receive cancellation and send completion remain caller-run.
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
            const event = try Display.decodeEvent(message, fds);
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
