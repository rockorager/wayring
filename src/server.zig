//! Allocation-free core server operations over generated protocol codecs.

const std = @import("std");
const ancillary = @import("ancillary.zig");
const connection = @import("connection.zig");
const io_uring = @import("io_uring.zig");
const metadata = @import("metadata.zig");
const objects = @import("objects.zig");
const tx = @import("tx.zig");
const wire = @import("wire.zig");

/// Application state attached to a typed object created by a generated event.
pub const NewObjectContext = struct {
    context: ?*anyopaque = null,
};

/// Metadata and application state assigned while admitting a decoded
/// `new_id` whose interface is not statically available in this module.
pub const NewObject = struct {
    interface: *const metadata.Interface,
    context: ?*anyopaque = null,
};

/// Interface, version, and application state for an untyped `new_id` created
/// by a generated server event constructor.
pub const NewEventObject = struct {
    interface: *const metadata.Interface,
    version: u32,
    context: ?*anyopaque = null,
};

pub const GlobalError = objects.Error || metadata.Error || error{
    NameExhausted,
    UnknownGlobal,
};

/// Immutable Linux identity captured from SO_PEERCRED when a client is admitted.
pub const Credentials = extern struct {
    pid: std.os.linux.pid_t,
    uid: std.os.linux.uid_t,
    gid: std.os.linux.gid_t,
};

pub const Binding = struct {
    peer: io_uring.Peer,
    credentials: Credentials,
    global: objects.Handle,
    resource: objects.Handle,
    version: u32,
};

pub const BindFn = *const fn (?*anyopaque, Binding) anyerror!?*anyopaque;

pub const Global = struct {
    interface: *const metadata.Interface,
    version: u32,
    context: ?*anyopaque,
    bind: ?BindFn = null,
};

/// Cold-path policy input for registry publication and bind authorization.
pub const GlobalVisibility = struct {
    peer: io_uring.Peer,
    credentials: Credentials,
    global: objects.Handle,
    interface: *const metadata.Interface,
    version: u32,
    global_context: ?*anyopaque,
};

/// Optional runtime-wide global policy. The predicate must remain stable for a
/// global's lifetime; remove and re-add a global to change its visibility.
pub const GlobalFilter = struct {
    context: ?*anyopaque = null,
    visible: *const fn (?*anyopaque, GlobalVisibility) bool,
};

/// Owns one listening descriptor and its persistent multishot accept state.
/// Socket creation, publication, path cleanup, CQE routing, and accepted-client
/// policy remain explicit at the caller boundary.
pub const Endpoint = struct {
    reactor: *io_uring.Reactor,
    fd: std.os.linux.fd_t,
    listener: io_uring.Listener = .{},

    /// Takes ownership of an already configured listening descriptor.
    pub fn init(reactor: *io_uring.Reactor, fd: std.os.linux.fd_t) Endpoint {
        return .{ .reactor = reactor, .fd = fd };
    }

    /// Queues the initial multishot accept without submitting it.
    pub inline fn prepareAccept(endpoint: *Endpoint) !void {
        try endpoint.listener.prepare(endpoint.reactor.ring, endpoint.fd);
    }

    /// Applies a listener CQE after `Reactor.route` selected `.listener`.
    pub inline fn complete(
        endpoint: *Endpoint,
        completion: std.os.linux.io_uring_cqe,
    ) !io_uring.Listener.Event {
        return endpoint.listener.complete(completion);
    }

    /// Queues accept cancellation without submitting it.
    pub inline fn prepareClose(endpoint: *Endpoint) !bool {
        return endpoint.listener.prepareStop(endpoint.reactor.ring);
    }

    /// Closes the listener only after both accept and cancel CQEs have settled.
    pub fn deinit(endpoint: *Endpoint) !void {
        if (!endpoint.listener.canDeinit()) return error.ListenerBusy;
        _ = std.os.linux.close(endpoint.fd);
        endpoint.* = undefined;
    }
};

/// Reactor-wide immutable global definitions shared by every client registry.
pub const Globals = struct {
    table: objects.Table(Global),
    next_name: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, max_globals: usize) GlobalError!Globals {
        return .{ .table = try objects.Table(Global).init(allocator, max_globals) };
    }

    pub fn deinit(globals: *Globals, allocator: std.mem.Allocator) void {
        globals.table.deinit(allocator);
        globals.* = undefined;
    }

    pub fn add(
        globals: *Globals,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) GlobalError!objects.Handle {
        return globals.addWithBinder(interface, version, context, null);
    }

    pub fn addWithBinder(
        globals: *Globals,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
        bind: ?BindFn,
    ) GlobalError!objects.Handle {
        try interface.validateVersion(version);
        if (globals.next_name == 0) return error.NameExhausted;
        const name = globals.next_name;
        globals.next_name +%= 1;
        return globals.table.insert(name, .{
            .interface = interface,
            .version = version,
            .context = context,
            .bind = bind,
        });
    }

    pub fn get(globals: *Globals, name: u32) GlobalError!*Global {
        return globals.table.get(name) orelse error.UnknownGlobal;
    }

    pub fn remove(globals: *Globals, handle: objects.Handle) GlobalError!Global {
        return globals.table.removeHandle(handle) orelse error.UnknownGlobal;
    }

    pub fn iterator(globals: *Globals) objects.Table(Global).Iterator {
        return globals.table.iterator();
    }

    pub fn cursor(globals: *Globals) GlobalCursor {
        return .{ .iterator = globals.iterator() };
    }
};

pub const GlobalCursor = struct {
    iterator: objects.Table(Global).Iterator,
    pending: ?objects.Table(Global).Entry = null,
};

pub fn DecodedRequest(comptime Interface: type) type {
    return struct {
        handle: objects.Handle,
        value: Interface.Request,
        destructor: bool,

        /// Applies object removal after the application has handled the request.
        /// Client-created IDs also queue wl_display.delete_id before removal.
        pub fn finish(
            decoded: @This(),
            comptime protocol: type,
            server_objects: anytype,
            queue: *tx.Queue,
        ) !void {
            if (!decoded.destructor) return;
            if (decoded.handle.id < objects.server_id_start) {
                _ = try Core(protocol).deleteClient(
                    server_objects,
                    queue,
                    decoded.handle,
                );
            } else {
                _ = try server_objects.removeLocal(decoded.handle);
            }
        }
    };
}

/// Validates and decodes an arbitrary generated request while preserving its
/// object until the application callback returns and calls `finish`.
pub fn decodeRequest(
    comptime Interface: type,
    server_objects: anytype,
    message: wire.Message,
    fds: *ancillary.FdQueue,
) !DecodedRequest(Interface) {
    const target = try server_objects.namespace.request(
        message.header.object_id,
        message.header.opcode,
    );
    if (target.object.interface != &Interface.info) return error.WrongInterface;
    const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse
        return error.UnknownObject;
    const value = if (@hasDecl(Interface, "decodeRequestObjects"))
        try Interface.decodeRequestObjects(&server_objects.namespace, message, fds)
    else
        try Interface.decodeRequest(message, fds);
    return .{
        .handle = handle,
        .value = value,
        .destructor = target.message.destructor,
    };
}

/// Encodes an arbitrary generated event and applies destructor lifecycle only
/// after every required frame is committed. Client-created objects preflight
/// the event and wl_display.delete_id together so backpressure cannot expose a
/// partial lifecycle transition.
pub fn sendEvent(
    comptime protocol: type,
    comptime Interface: type,
    server_objects: anytype,
    queue: *tx.Queue,
    handle: objects.Handle,
    event: Interface.Event,
) !void {
    const object = server_objects.namespace.resolve(handle) orelse
        return error.StaleHandle;
    if (object.interface != &Interface.info) return error.WrongInterface;
    const opcode: u16 = @intCast(@intFromEnum(std.meta.activeTag(event)));
    const message = try object.interface.event(opcode, object.version);
    if (@hasDecl(Interface, "validateEventObjects"))
        try Interface.validateEventObjects(&server_objects.namespace, event);

    if (message.destructor and handle.id < objects.server_id_start) {
        const event_size = try Interface.eventSize(event);
        const delete_id_size = try protocol.wl_display.eventSize(.{
            .delete_id = .{ .id = handle.id },
        });
        try queue.ensureCapacity(event_size + delete_id_size, 0);
    }

    try Interface.encodeEvent(queue, handle.id, event);
    if (!message.destructor) return;
    if (handle.id < objects.server_id_start) {
        try protocol.wl_display.encodeEvent(queue, objects.display_id, .{
            .delete_id = .{ .id = handle.id },
        });
        _ = server_objects.removeClient(handle) catch unreachable;
    } else {
        _ = server_objects.removeLocal(handle) catch unreachable;
    }
}

pub fn Core(comptime protocol: type) type {
    return struct {
        pub const Display = protocol.wl_display;
        pub const Registry = protocol.wl_registry;
        pub const Callback = protocol.wl_callback;

        pub const Error = objects.ServerObjectsError || GlobalError ||
            connection.Error ||
            Display.EncodeError || Display.DecodeError ||
            Registry.EncodeError || Registry.DecodeError ||
            Callback.EncodeError || metadata.Error || error{
            WrongInterface,
            InterfaceMismatch,
            UnsupportedGlobalVersion,
        };

        pub const DisplayAction = union(enum) {
            sync: objects.Handle,
            get_registry: objects.Handle,
        };

        /// Stops request dispatch and appends the terminal protocol error after
        /// already-queued events. Failure closes immediately rather than
        /// leaving a connection in a partially terminal state.
        pub fn postError(
            actor: *connection.Actor,
            object_id: u32,
            code: u32,
            message: []const u8,
        ) Error!void {
            try actor.beginProtocolError();
            errdefer actor.beginClose();
            try Display.encodeEvent(&actor.transmit, objects.display_id, .{
                .@"error" = .{
                    .object_id = object_id,
                    .code = code,
                    .message = message,
                },
            });
            try actor.commitProtocolError();
        }

        pub const RequestResult = union(enum) {
            dispatched: usize,
            terminal: struct {
                dispatched: usize,
                object_id: ?u32,
                cause: anyerror,
                error_queued: bool,
            },
        };

        const DisplayErrorCode = enum(u32) {
            invalid_object = 0,
            invalid_method = 1,
            no_memory = 2,
            implementation = 3,
        };

        /// Dispatches complete requests and converts framing, object lookup,
        /// decoding, and handler failures into a terminal wl_display.error.
        /// Applications may post a more specific error themselves and return
        /// `.stop`; otherwise this provides the safe default failure policy.
        pub fn dispatchRequests(
            actor: *connection.Actor,
            namespace: anytype,
            bytes: *[]const u8,
            context: anytype,
        ) RequestResult {
            if (!actor.canDispatch()) return .{ .dispatched = 0 };
            var count: usize = 0;
            while (true) {
                const message = actor.nextMessage(bytes) catch |cause|
                    return terminalRequest(actor, count, null, cause);
                const complete = message orelse return .{ .dispatched = count };
                const target = namespace.request(
                    complete.header.object_id,
                    complete.header.opcode,
                ) catch |cause| return terminalRequest(
                    actor,
                    count,
                    complete.header.object_id,
                    cause,
                );
                const control = context.request(
                    target,
                    complete,
                    &actor.received_fds,
                ) catch |cause| return terminalRequest(
                    actor,
                    count,
                    complete.header.object_id,
                    cause,
                );
                count += 1;
                if (control == .stop) return .{ .dispatched = count };
            }
        }

        /// Selected-buffer counterpart to `dispatchRequests`. The kernel buffer
        /// is returned exactly once; CQE routing, rearming, and submission stay
        /// visible to the caller.
        pub inline fn receivedRequests(
            actor: *connection.Actor,
            namespace: anytype,
            receiver: anytype,
            completion: std.os.linux.io_uring_cqe,
            context: anytype,
        ) !RequestResult {
            const received = receiver.decodeCompletion(completion) catch |cause|
                return terminalRequest(actor, 0, null, cause);
            _ = actor.ingestControl(received.control) catch |cause| {
                receiver.release(received) catch {};
                return terminalRequest(actor, 0, null, cause);
            };
            var payload = received.payload;
            const result = dispatchRequests(actor, namespace, &payload, context);
            try receiver.release(received);
            return result;
        }

        /// Reactor-aware selected-buffer dispatch. In addition to returning the
        /// buffer exactly once, this records receive-buffer progress for the
        /// deferred rearm scheduler.
        pub inline fn receivedRequestsReactor(
            actor: *connection.Actor,
            namespace: anytype,
            reactor: *io_uring.Reactor,
            peer: io_uring.Peer,
            completion: std.os.linux.io_uring_cqe,
            context: anytype,
        ) !RequestResult {
            const receiver = try reactor.getReceiver(peer);
            const received = receiver.decodeCompletion(completion) catch |cause| {
                reactor.noteReceiveBufferReturned(completion);
                return terminalRequest(actor, 0, null, cause);
            };
            _ = actor.ingestControl(received.control) catch |cause| {
                reactor.releaseReceived(peer, received) catch {};
                return terminalRequest(actor, 0, null, cause);
            };
            var payload = received.payload;
            const result = dispatchRequests(actor, namespace, &payload, context);
            try reactor.releaseReceived(peer, received);
            return result;
        }

        fn terminalRequest(
            actor: *connection.Actor,
            dispatched: usize,
            object_id: ?u32,
            cause: anyerror,
        ) RequestResult {
            if (cause == error.Disconnected) {
                actor.beginClose();
                return .{ .terminal = .{
                    .dispatched = dispatched,
                    .object_id = object_id,
                    .cause = cause,
                    .error_queued = false,
                } };
            }
            var error_queued = actor.lifecycle == .draining;
            if (actor.canDispatch()) {
                postError(
                    actor,
                    object_id orelse objects.display_id,
                    displayErrorCode(cause),
                    @errorName(cause),
                ) catch actor.beginClose();
                error_queued = actor.lifecycle == .draining;
            }
            return .{ .terminal = .{
                .dispatched = dispatched,
                .object_id = object_id,
                .cause = cause,
                .error_queued = error_queued,
            } };
        }

        fn displayErrorCode(cause: anyerror) u32 {
            return @intFromEnum(switch (cause) {
                error.UnknownObject => DisplayErrorCode.invalid_object,
                error.UnknownOpcode, error.UnsupportedVersion => .invalid_method,
                error.OutOfMemory, error.Full => .no_memory,
                else => .implementation,
            });
        }

        pub fn decodeDisplayRequest(
            server_objects: anytype,
            message: wire.Message,
            fds: *ancillary.FdQueue,
            context: ?*anyopaque,
        ) Error!DisplayAction {
            try requireMessage(server_objects, message, &Display.info);
            const request = try Display.decodeRequest(message, fds);
            return switch (request) {
                .sync => |sync_request| .{ .sync = try server_objects.insertClient(
                    sync_request.callback,
                    &Callback.info,
                    1,
                    context,
                ) },
                .get_registry => |registry_request| .{
                    .get_registry = try server_objects.insertClient(
                        registry_request.registry,
                        &Registry.info,
                        1,
                        context,
                    ),
                },
            };
        }

        pub fn decodeRegistryRequest(
            server_objects: anytype,
            registry: objects.Handle,
            message: wire.Message,
            fds: *ancillary.FdQueue,
        ) Error!Registry.Request {
            try requireObject(server_objects, registry, &Registry.info);
            if (message.header.object_id != registry.id) return error.StaleHandle;
            try requireMessage(server_objects, message, &Registry.info);
            return Registry.decodeRequest(message, fds);
        }

        pub fn bindClient(
            server_objects: anytype,
            request: protocol.DynamicNewId,
            interface: *const metadata.Interface,
            advertised_version: u32,
            context: ?*anyopaque,
        ) Error!objects.Handle {
            if (!std.mem.eql(u8, request.interface, interface.name))
                return error.InterfaceMismatch;
            if (request.version == 0 or request.version > advertised_version or
                request.version > interface.version)
                return error.UnsupportedGlobalVersion;
            return server_objects.insertClient(
                request.id,
                interface,
                request.version,
                context,
            );
        }

        pub fn bindGlobal(
            server_objects: anytype,
            globals: *Globals,
            request: Registry.Request,
        ) Error!objects.Handle {
            const binding = switch (request) {
                .bind => |value| value,
            };
            const global = try globals.get(binding.name);
            return bindClient(
                server_objects,
                binding.id,
                global.interface,
                global.version,
                global.context,
            );
        }

        pub fn sendGlobalEntry(
            server_objects: anytype,
            queue: *tx.Queue,
            registry: objects.Handle,
            name: u32,
            global: Global,
        ) Error!void {
            return sendGlobal(
                server_objects,
                queue,
                registry,
                name,
                global.interface,
                global.version,
            );
        }

        /// Sends at most one global. A failed enqueue remains pending so the
        /// same entry is retried after the connection drains.
        pub fn advertiseNext(
            server_objects: anytype,
            queue: *tx.Queue,
            registry: objects.Handle,
            cursor: *GlobalCursor,
        ) Error!bool {
            if (cursor.pending == null)
                cursor.pending = cursor.iterator.next() orelse return false;
            const entry = cursor.pending.?;
            try sendGlobalEntry(
                server_objects,
                queue,
                registry,
                entry.handle.id,
                entry.value.*,
            );
            cursor.pending = null;
            return true;
        }

        pub fn sendGlobal(
            server_objects: anytype,
            queue: *tx.Queue,
            registry: objects.Handle,
            name: u32,
            interface: *const metadata.Interface,
            advertised_version: u32,
        ) Error!void {
            try requireObject(server_objects, registry, &Registry.info);
            if (advertised_version == 0 or advertised_version > interface.version)
                return error.UnsupportedGlobalVersion;
            try Registry.encodeEvent(queue, registry.id, .{ .global = .{
                .name = name,
                .interface = interface.name,
                .version = advertised_version,
            } });
        }

        pub fn sendGlobalRemove(
            server_objects: anytype,
            queue: *tx.Queue,
            registry: objects.Handle,
            name: u32,
        ) Error!void {
            try requireObject(server_objects, registry, &Registry.info);
            try Registry.encodeEvent(queue, registry.id, .{
                .global_remove = .{ .name = name },
            });
        }

        /// Queues callback.done and display.delete_id as one preflighted batch.
        /// Both frames coalesce behind the connection's single send SQE.
        pub fn completeSync(
            server_objects: anytype,
            queue: *tx.Queue,
            callback: objects.Handle,
            callback_data: u32,
        ) Error!void {
            try sendEvent(protocol, Callback, server_objects, queue, callback, .{
                .done = .{ .callback_data = callback_data },
            });
        }

        pub fn deleteClient(
            server_objects: anytype,
            queue: *tx.Queue,
            handle: objects.Handle,
        ) Error!objects.Object {
            if (handle.id < 2 or handle.id >= objects.server_id_start)
                return error.InvalidClientId;
            if (server_objects.namespace.resolve(handle) == null)
                return error.StaleHandle;
            try Display.encodeEvent(queue, objects.display_id, .{
                .delete_id = .{ .id = handle.id },
            });
            return server_objects.removeClient(handle) catch unreachable;
        }

        fn requireObject(
            server_objects: anytype,
            handle: objects.Handle,
            interface: *const metadata.Interface,
        ) Error!void {
            const object = server_objects.namespace.resolve(handle) orelse
                return error.StaleHandle;
            if (object.interface != interface) return error.WrongInterface;
        }

        fn requireMessage(
            server_objects: anytype,
            message: wire.Message,
            interface: *const metadata.Interface,
        ) Error!void {
            const dispatch = try server_objects.namespace.request(
                message.header.object_id,
                message.header.opcode,
            );
            if (dispatch.object.interface != interface) return error.WrongInterface;
        }
    };
}

/// Couples transport slots to server object namespaces while sharing physical
/// object nodes across every client on the reactor.
pub fn SharedClients(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const ProtocolCore = Core(protocol);

        const ClientSlot = struct {
            generation: u32 = 0,
            credentials: Credentials = undefined,
        };

        pub const Iterator = struct {
            clients: *const Self,
            index: usize = 0,

            pub fn next(self: *Iterator) ?io_uring.Peer {
                while (self.index < self.clients.slot_storage.len) {
                    const slot = self.index;
                    self.index += 1;
                    const generation = self.clients.slot_storage[slot].generation;
                    if (generation != 0) return .{
                        .slot = @intCast(slot),
                        .generation = generation,
                    };
                }
                return null;
            }
        };

        reactor: *io_uring.Reactor,
        object_pool: objects.SharedObjectPool,
        client_storage: []objects.SharedServerObjects,
        bucket_storage: []objects.SharedObjectBucket,
        slot_storage: []ClientSlot,
        buckets_per_client: usize,
        object_quota: usize,

        pub fn init(
            allocator: std.mem.Allocator,
            reactor: *io_uring.Reactor,
            object_capacity: usize,
            object_quota: usize,
            buckets_per_client: usize,
        ) !Self {
            const max_connections = reactor.actor_storage.len;
            if (max_connections == 0 or object_capacity < max_connections or
                object_quota == 0 or object_quota > object_capacity or
                buckets_per_client < 2 or !std.math.isPowerOfTwo(buckets_per_client))
                return error.InvalidConfig;
            const bucket_count = std.math.mul(
                usize,
                max_connections,
                buckets_per_client,
            ) catch return error.CapacityOverflow;

            var object_pool = try objects.SharedObjectPool.init(allocator, object_capacity);
            errdefer object_pool.deinit(allocator);
            try object_pool.reserve(max_connections);
            const client_storage = try allocator.alloc(
                objects.SharedServerObjects,
                max_connections,
            );
            errdefer allocator.free(client_storage);
            const bucket_storage = try allocator.alloc(
                objects.SharedObjectBucket,
                bucket_count,
            );
            errdefer allocator.free(bucket_storage);
            @memset(bucket_storage, .{});
            const slot_storage = try allocator.alloc(ClientSlot, max_connections);
            errdefer allocator.free(slot_storage);
            @memset(slot_storage, .{});
            return .{
                .reactor = reactor,
                .object_pool = object_pool,
                .client_storage = client_storage,
                .bucket_storage = bucket_storage,
                .slot_storage = slot_storage,
                .buckets_per_client = buckets_per_client,
                .object_quota = object_quota,
            };
        }

        pub fn deinit(clients: *Self, allocator: std.mem.Allocator) void {
            for (clients.slot_storage) |slot| std.debug.assert(slot.generation == 0);
            std.debug.assert(
                clients.object_pool.reserved_count == clients.slot_storage.len,
            );
            allocator.free(clients.slot_storage);
            allocator.free(clients.bucket_storage);
            allocator.free(clients.client_storage);
            clients.object_pool.deinit(allocator);
            clients.* = undefined;
        }

        /// Consumes the accepted descriptor, initializes wl_display from a
        /// reserved node, and queues the first receive without submitting.
        pub fn admit(
            clients: *Self,
            accepted: io_uring.Listener.Accepted,
            actor_config: io_uring.ActorConfig,
            display_context: ?*anyopaque,
        ) !io_uring.Peer {
            const identity = peerCredentials(accepted.fd) catch |err| {
                _ = std.os.linux.close(accepted.fd);
                return err;
            };
            const peer = try clients.reactor.admit(accepted, actor_config);
            errdefer clients.reactor.destroyPeer(peer) catch unreachable;
            const slot: usize = peer.slot;
            std.debug.assert(clients.slot_storage[slot].generation == 0);
            clients.client_storage[slot] = try objects.SharedServerObjects.initReserved(
                &clients.object_pool,
                clients.buckets(slot),
                peer.generation,
                clients.object_quota,
                &ProtocolCore.Display.info,
                display_context,
            );
            var objects_live = true;
            errdefer if (objects_live) {
                clients.client_storage[slot].deinit();
                clients.object_pool.restoreReservation();
            };
            try clients.reactor.prepareReceive(peer);
            clients.slot_storage[slot] = .{
                .generation = peer.generation,
                .credentials = identity,
            };
            objects_live = false;
            return peer;
        }

        pub fn get(
            clients: *Self,
            peer: io_uring.Peer,
        ) !*objects.SharedServerObjects {
            _ = try clients.reactor.getActor(peer);
            const slot: usize = peer.slot;
            if (clients.slot_storage[slot].generation != peer.generation)
                return error.StaleHandle;
            return &clients.client_storage[slot];
        }

        pub fn getCredentials(clients: *Self, peer: io_uring.Peer) !Credentials {
            _ = try clients.get(peer);
            return clients.slot_storage[peer.slot].credentials;
        }

        pub fn iterator(clients: *const Self) Iterator {
            return .{ .clients = clients };
        }

        /// Queues asynchronous socket-I/O cancellation without submitting it.
        pub inline fn prepareClose(clients: *Self, peer: io_uring.Peer) !bool {
            _ = try clients.get(peer);
            return clients.reactor.prepareClose(peer);
        }

        /// Releases all client objects in O(1), restores its admission reserve,
        /// closes the socket, and recycles the reactor slot.
        pub fn destroy(clients: *Self, peer: io_uring.Peer) !void {
            const actor = try clients.reactor.getActor(peer);
            if (!actor.canDeinit()) return error.ActorBusy;
            const server_objects = try clients.get(peer);
            server_objects.deinit();
            clients.slot_storage[peer.slot].generation = 0;
            clients.object_pool.restoreReservation();
            clients.reactor.destroyPeer(peer) catch unreachable;
        }

        fn buckets(clients: *Self, slot: usize) []objects.SharedObjectBucket {
            const start = slot * clients.buckets_per_client;
            return clients.bucket_storage[start..][0..clients.buckets_per_client];
        }
    };
}

fn peerCredentials(fd: std.os.linux.fd_t) !Credentials {
    const linux = std.os.linux;
    var credentials: Credentials = undefined;
    var length: linux.socklen_t = @sizeOf(Credentials);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        std.mem.asBytes(&credentials).ptr,
        &length,
    );
    if (linux.errno(result) != .SUCCESS) return error.PeerCredentialsFailed;
    if (length != @sizeOf(Credentials)) return error.InvalidPeerCredentials;
    return credentials;
}

const RegistrySubscriptions = struct {
    const end = std.math.maxInt(u32);

    const Node = struct {
        handle: objects.Handle = undefined,
        next: u32 = end,
        sequence: u64 = 0,
        initial: ?GlobalCursor = null,
    };

    const Slot = struct {
        generation: u32 = 0,
        head: u32 = end,
        tail: u32 = end,
        count: u32 = 0,
        initial_count: u32 = 0,
    };

    const InitialUpdate = struct {
        slot_index: usize = 0,
        slot_generation: u32 = 0,
        node: u32 = end,
        slot_started: bool = false,
    };

    const Update = struct {
        handle: objects.Handle,
        change: union(enum) {
            added: Global,
            removed: Global,
        },
        sequence_limit: u64,
        slot_index: usize = 0,
        slot_generation: u32 = 0,
        node: u32 = end,
        slot_started: bool = false,
    };

    const Candidate = struct {
        peer: io_uring.Peer,
        registry: objects.Handle,
        node: u32,
    };

    nodes: []Node,
    slots: []Slot,
    free_head: u32,
    available_count: usize,
    initial_count: usize = 0,
    initial_update: InitialUpdate = .{},
    next_sequence: u64 = 1,

    fn init(
        allocator: std.mem.Allocator,
        max_connections: usize,
        capacity: usize,
    ) !RegistrySubscriptions {
        if (max_connections == 0 or capacity == 0 or capacity > end)
            return error.InvalidConfig;
        const nodes = try allocator.alloc(Node, capacity);
        errdefer allocator.free(nodes);
        for (nodes, 0..) |*node, index| {
            node.next = if (index + 1 < nodes.len) @intCast(index + 1) else end;
        }
        const slots = try allocator.alloc(Slot, max_connections);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        return .{
            .nodes = nodes,
            .slots = slots,
            .free_head = 0,
            .available_count = capacity,
        };
    }

    fn deinit(subscriptions: *RegistrySubscriptions, allocator: std.mem.Allocator) void {
        std.debug.assert(subscriptions.available_count == subscriptions.nodes.len);
        std.debug.assert(subscriptions.initial_count == 0);
        for (subscriptions.slots) |slot| std.debug.assert(slot.generation == 0);
        allocator.free(subscriptions.slots);
        allocator.free(subscriptions.nodes);
        subscriptions.* = undefined;
    }

    fn add(
        subscriptions: *RegistrySubscriptions,
        peer: io_uring.Peer,
        registry: objects.Handle,
        initial: ?GlobalCursor,
    ) !void {
        const slot = &subscriptions.slots[peer.slot];
        if (slot.generation == 0) slot.generation = peer.generation;
        if (slot.generation != peer.generation) return error.StaleHandle;
        var current = slot.head;
        while (current != end) : (current = subscriptions.nodes[current].next) {
            const existing = subscriptions.nodes[current].handle;
            if (existing.id == registry.id and existing.generation == registry.generation)
                return error.DuplicateId;
        }
        if (subscriptions.free_head == end) return error.Full;
        const index = subscriptions.free_head;
        subscriptions.free_head = subscriptions.nodes[index].next;
        subscriptions.available_count -= 1;
        const sequence = subscriptions.next_sequence;
        subscriptions.next_sequence +%= 1;
        if (subscriptions.next_sequence == 0) subscriptions.next_sequence = 1;
        subscriptions.nodes[index] = .{
            .handle = registry,
            .sequence = sequence,
            .initial = initial,
        };
        if (slot.tail == end)
            slot.head = index
        else
            subscriptions.nodes[slot.tail].next = index;
        slot.tail = index;
        slot.count += 1;
        if (initial != null) {
            slot.initial_count += 1;
            subscriptions.initial_count += 1;
            subscriptions.initial_update = .{};
        }
    }

    fn removePeer(subscriptions: *RegistrySubscriptions, peer: io_uring.Peer) void {
        const slot = &subscriptions.slots[peer.slot];
        if (slot.generation != peer.generation) return;
        if (slot.head != end) {
            subscriptions.nodes[slot.tail].next = subscriptions.free_head;
            subscriptions.free_head = slot.head;
            subscriptions.available_count += @intCast(slot.count);
            subscriptions.initial_count -= @intCast(slot.initial_count);
        }
        slot.* = .{};
    }

    fn nextInitial(subscriptions: *RegistrySubscriptions) ?Candidate {
        const update = &subscriptions.initial_update;
        while (update.slot_index < subscriptions.slots.len) {
            const slot = &subscriptions.slots[update.slot_index];
            if (!update.slot_started) {
                update.slot_started = true;
                update.slot_generation = slot.generation;
                update.node = slot.head;
            }
            if (slot.generation == 0 or
                slot.generation != update.slot_generation or
                update.node == end)
            {
                update.slot_index += 1;
                update.slot_started = false;
                continue;
            }
            const index = update.node;
            const node = &subscriptions.nodes[index];
            if (node.initial == null) {
                update.node = node.next;
                continue;
            }
            return .{
                .peer = .{
                    .slot = @intCast(update.slot_index),
                    .generation = update.slot_generation,
                },
                .registry = node.handle,
                .node = index,
            };
        }
        std.debug.assert(subscriptions.initial_count == 0);
        return null;
    }

    fn completeInitial(subscriptions: *RegistrySubscriptions, candidate: Candidate) void {
        const node = &subscriptions.nodes[candidate.node];
        std.debug.assert(node.initial != null);
        node.initial = null;
        const slot = &subscriptions.slots[candidate.peer.slot];
        slot.initial_count -= 1;
        subscriptions.initial_count -= 1;
        subscriptions.initial_update.node = node.next;
    }

    fn updateAdded(
        subscriptions: RegistrySubscriptions,
        handle: objects.Handle,
        global: Global,
    ) Update {
        return .{
            .handle = handle,
            .change = .{ .added = global },
            .sequence_limit = subscriptions.next_sequence -% 1,
        };
    }

    fn updateRemoved(
        subscriptions: RegistrySubscriptions,
        handle: objects.Handle,
        global: Global,
    ) Update {
        return .{
            .handle = handle,
            .change = .{ .removed = global },
            .sequence_limit = subscriptions.next_sequence -% 1,
        };
    }

    fn next(
        subscriptions: *RegistrySubscriptions,
        update: *Update,
    ) ?Candidate {
        while (update.slot_index < subscriptions.slots.len) {
            const slot = &subscriptions.slots[update.slot_index];
            if (!update.slot_started) {
                update.slot_started = true;
                update.slot_generation = slot.generation;
                update.node = slot.head;
            }
            if (slot.generation == 0 or
                slot.generation != update.slot_generation or
                update.node == end)
            {
                update.slot_index += 1;
                update.slot_started = false;
                continue;
            }
            const index = update.node;
            const node = &subscriptions.nodes[index];
            if (node.sequence > update.sequence_limit) {
                update.node = node.next;
                continue;
            }
            return .{
                .peer = .{
                    .slot = @intCast(update.slot_index),
                    .generation = update.slot_generation,
                },
                .registry = node.handle,
                .node = index,
            };
        }
        return null;
    }

    fn advance(subscriptions: RegistrySubscriptions, update: *Update, node: u32) void {
        std.debug.assert(update.node == node);
        update.node = subscriptions.nodes[node].next;
    }
};

/// Owns the server's cold-path listener, global table, and shared per-client
/// object storage. The caller retains CQE polling, routing, connection event
/// switches, protocol dispatch, batching, and submission policy.
pub fn Runtime(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const ProtocolCore = Core(protocol);
        pub const Clients = SharedClients(protocol);

        endpoint: Endpoint,
        clients: Clients,
        globals: Globals,
        registries: RegistrySubscriptions,
        global_update: ?RegistrySubscriptions.Update = null,
        actor_config: io_uring.ActorConfig,
        global_filter: ?GlobalFilter,

        pub const PublishResult = union(enum) {
            sent: io_uring.Peer,
            blocked: io_uring.Peer,
            complete,
        };

        pub const Config = struct {
            actor: io_uring.ActorConfig,
            object_capacity: usize,
            object_quota: usize,
            buckets_per_client: usize,
            max_globals: usize,
            registry_capacity: usize,
            /// Applied to initial listings, later add/remove events, and binds.
            global_filter: ?GlobalFilter = null,
        };

        /// Takes ownership of `listener_fd`. Initialization failure closes it.
        pub fn init(
            allocator: std.mem.Allocator,
            reactor: *io_uring.Reactor,
            listener_fd: std.os.linux.fd_t,
            config: Config,
        ) !Self {
            var endpoint = Endpoint.init(reactor, listener_fd);
            errdefer endpoint.deinit() catch unreachable;
            var clients = try Clients.init(
                allocator,
                reactor,
                config.object_capacity,
                config.object_quota,
                config.buckets_per_client,
            );
            errdefer clients.deinit(allocator);
            var globals = try Globals.init(allocator, config.max_globals);
            errdefer globals.deinit(allocator);
            var registries = try RegistrySubscriptions.init(
                allocator,
                reactor.actor_storage.len,
                config.registry_capacity,
            );
            errdefer registries.deinit(allocator);
            return .{
                .endpoint = endpoint,
                .clients = clients,
                .globals = globals,
                .registries = registries,
                .actor_config = config.actor,
                .global_filter = config.global_filter,
            };
        }

        fn globalVisible(
            runtime: *Self,
            peer: io_uring.Peer,
            handle: objects.Handle,
            global: Global,
        ) !bool {
            const filter = runtime.global_filter orelse return true;
            return filter.visible(filter.context, .{
                .peer = peer,
                .credentials = try runtime.clients.getCredentials(peer),
                .global = handle,
                .interface = global.interface,
                .version = global.version,
                .global_context = global.context,
            });
        }

        pub inline fn prepareAccept(runtime: *Self) !void {
            try runtime.endpoint.prepareAccept();
        }

        /// Applies a routed listener completion. Accepted descriptors are
        /// transactionally admitted and have their first receive queued.
        pub fn completeListener(
            runtime: *Self,
            completion: std.os.linux.io_uring_cqe,
            display_context: ?*anyopaque,
        ) !?io_uring.Peer {
            return switch (try runtime.endpoint.complete(completion)) {
                .accepted => |accepted| try runtime.clients.admit(
                    accepted,
                    runtime.actor_config,
                    display_context,
                ),
                .accept_stopped, .cancel_complete => null,
            };
        }

        /// Applies a core display request, persisting each new registry's
        /// initial listing and subscription to later global changes. Registration
        /// failure rolls back the unpublished object so terminal error handling
        /// can close without leaked state.
        pub fn decodeDisplayRequest(
            runtime: *Self,
            peer: io_uring.Peer,
            message: wire.Message,
            fds: *ancillary.FdQueue,
            context: ?*anyopaque,
        ) !ProtocolCore.DisplayAction {
            const server_objects = try runtime.clients.get(peer);
            const action = try ProtocolCore.decodeDisplayRequest(
                server_objects,
                message,
                fds,
                context,
            );
            switch (action) {
                .sync => {},
                .get_registry => |registry| runtime.registries.add(
                    peer,
                    registry,
                    if (runtime.globals.table.len() == 0)
                        null
                    else
                        runtime.globals.cursor(),
                ) catch |err| {
                    _ = server_objects.cancelClient(registry) catch unreachable;
                    return err;
                },
            }
            return action;
        }

        /// Adds a global and snapshots the registry subscriptions that must be
        /// notified. Registries created later receive it through initial listing.
        pub fn addGlobal(
            runtime: *Self,
            interface: *const metadata.Interface,
            version: u32,
            context: ?*anyopaque,
        ) !objects.Handle {
            return runtime.addGlobalWithBinder(interface, version, context, null);
        }

        pub fn addGlobalWithBinder(
            runtime: *Self,
            interface: *const metadata.Interface,
            version: u32,
            context: ?*anyopaque,
            bind: ?BindFn,
        ) !objects.Handle {
            if (runtime.global_update != null or runtime.registries.initial_count != 0)
                return error.GlobalUpdateActive;
            const handle = try runtime.globals.addWithBinder(
                interface,
                version,
                context,
                bind,
            );
            runtime.global_update = runtime.registries.updateAdded(
                handle,
                (try runtime.globals.get(handle.id)).*,
            );
            return handle;
        }

        /// Inserts a decoded registry binding, then lets the global activate
        /// per-client resource state. Failed activation cancels the unpublished
        /// object without invoking its removal hook.
        pub fn bindGlobal(
            runtime: *Self,
            peer: io_uring.Peer,
            request: ProtocolCore.Registry.Request,
        ) !objects.Handle {
            const binding = switch (request) {
                .bind => |value| value,
            };
            const global_handle = runtime.globals.table.lookupHandle(binding.name) orelse
                return error.UnknownGlobal;
            const global = runtime.globals.table.resolve(global_handle) orelse unreachable;
            if (!try runtime.globalVisible(peer, global_handle, global.*))
                return error.UnknownGlobal;
            const interface = global.interface;
            const advertised_version = global.version;
            const global_context = global.context;
            const binder = global.bind;
            const credentials = try runtime.clients.getCredentials(peer);
            const server_objects = try runtime.clients.get(peer);
            const resource = try ProtocolCore.bindClient(
                server_objects,
                binding.id,
                interface,
                advertised_version,
                if (binder == null) global_context else null,
            );
            errdefer _ = server_objects.cancelClient(resource) catch unreachable;
            if (binder) |activate| {
                const resource_context = try activate(global_context, .{
                    .peer = peer,
                    .credentials = credentials,
                    .global = global_handle,
                    .resource = resource,
                    .version = binding.id.version,
                });
                server_objects.namespace.resolve(resource).?.context = resource_context;
            }
            return resource;
        }

        pub fn setRemovalHook(
            runtime: *Self,
            peer: io_uring.Peer,
            hook: ?objects.RemovalHook,
        ) !void {
            const server_objects = try runtime.clients.get(peer);
            server_objects.setRemovalHook(hook);
        }

        /// Removes a global immediately and snapshots existing registries for
        /// resumable global_remove publication.
        pub fn removeGlobal(runtime: *Self, handle: objects.Handle) !void {
            if (runtime.global_update != null or runtime.registries.initial_count != 0)
                return error.GlobalUpdateActive;
            const removed = try runtime.globals.remove(handle);
            runtime.global_update = runtime.registries.updateRemoved(handle, removed);
        }

        /// Queues at most one global event, finishing an active table mutation
        /// before runtime-owned initial registry listings. Backpressure leaves
        /// the cursor on the same event; successful publication returns the
        /// affected peer so callers can prepare its send SQE without scanning.
        pub fn publishNext(runtime: *Self) !PublishResult {
            if (runtime.global_update) |*update| {
                while (runtime.registries.next(update)) |candidate| {
                    const actor = runtime.clients.reactor.getActor(candidate.peer) catch {
                        runtime.registries.advance(update, candidate.node);
                        continue;
                    };
                    if (!actor.canDispatch()) {
                        runtime.registries.advance(update, candidate.node);
                        continue;
                    }
                    const server_objects = runtime.clients.get(candidate.peer) catch {
                        runtime.registries.advance(update, candidate.node);
                        continue;
                    };
                    const registry_object = server_objects.namespace.resolve(candidate.registry) orelse {
                        runtime.registries.advance(update, candidate.node);
                        continue;
                    };
                    if (registry_object.interface != &ProtocolCore.Registry.info) {
                        runtime.registries.advance(update, candidate.node);
                        continue;
                    }
                    const visibility_global = switch (update.change) {
                        .added => |value| value,
                        .removed => |value| value,
                    };
                    if (!try runtime.globalVisible(
                        candidate.peer,
                        update.handle,
                        visibility_global,
                    )) {
                        runtime.registries.advance(update, candidate.node);
                        continue;
                    }
                    switch (update.change) {
                        .added => |global| ProtocolCore.sendGlobalEntry(
                            server_objects,
                            &actor.transmit,
                            candidate.registry,
                            update.handle.id,
                            global,
                        ) catch |err| switch (err) {
                            error.ByteBudgetExceeded, error.Exhausted => return .{ .blocked = candidate.peer },
                            else => return err,
                        },
                        .removed => ProtocolCore.sendGlobalRemove(
                            server_objects,
                            &actor.transmit,
                            candidate.registry,
                            update.handle.id,
                        ) catch |err| switch (err) {
                            error.ByteBudgetExceeded, error.Exhausted => return .{ .blocked = candidate.peer },
                            else => return err,
                        },
                    }
                    runtime.registries.advance(update, candidate.node);
                    return .{ .sent = candidate.peer };
                }
                runtime.global_update = null;
            }

            while (runtime.registries.nextInitial()) |candidate| {
                const actor = runtime.clients.reactor.getActor(candidate.peer) catch {
                    runtime.registries.completeInitial(candidate);
                    continue;
                };
                if (!actor.canDispatch()) {
                    runtime.registries.completeInitial(candidate);
                    continue;
                }
                const server_objects = runtime.clients.get(candidate.peer) catch {
                    runtime.registries.completeInitial(candidate);
                    continue;
                };
                const registry_object = server_objects.namespace.resolve(candidate.registry) orelse {
                    runtime.registries.completeInitial(candidate);
                    continue;
                };
                if (registry_object.interface != &ProtocolCore.Registry.info) {
                    runtime.registries.completeInitial(candidate);
                    continue;
                }
                const cursor = &runtime.registries.nodes[candidate.node].initial.?;
                var sent = false;
                while (!sent) {
                    if (cursor.pending == null)
                        cursor.pending = cursor.iterator.next() orelse break;
                    const entry = cursor.pending.?;
                    if (!try runtime.globalVisible(candidate.peer, entry.handle, entry.value.*)) {
                        cursor.pending = null;
                        continue;
                    }
                    ProtocolCore.sendGlobalEntry(
                        server_objects,
                        &actor.transmit,
                        candidate.registry,
                        entry.handle.id,
                        entry.value.*,
                    ) catch |err| switch (err) {
                        error.ByteBudgetExceeded, error.Exhausted => return .{ .blocked = candidate.peer },
                        else => return err,
                    };
                    cursor.pending = null;
                    sent = true;
                }
                if (!sent) {
                    runtime.registries.completeInitial(candidate);
                    continue;
                }
                return .{ .sent = candidate.peer };
            }
            return .complete;
        }

        /// Releases registry subscriptions and then the fully quiesced client.
        pub fn destroyClient(runtime: *Self, peer: io_uring.Peer) !void {
            try runtime.clients.destroy(peer);
            runtime.registries.removePeer(peer);
        }

        pub inline fn prepareEndpointClose(runtime: *Self) !bool {
            return runtime.endpoint.prepareClose();
        }

        pub fn deinit(runtime: *Self, allocator: std.mem.Allocator) !void {
            if (!runtime.endpoint.listener.canDeinit()) return error.ListenerBusy;
            var peers = runtime.clients.iterator();
            if (peers.next() != null) return error.ClientsActive;
            runtime.registries.deinit(allocator);
            runtime.globals.deinit(allocator);
            runtime.clients.deinit(allocator);
            runtime.endpoint.deinit() catch unreachable;
            runtime.* = undefined;
        }
    };
}

/// Allocation-free completion driver for a server `Runtime`. Initialization
/// allocates one intrusive pending-work node per reactor connection slot; CQE
/// processing and request dispatch allocate nothing. Ring submission remains
/// explicit so owned- and borrowed-ring users share the same batching policy.
pub fn Driver(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const ServerRuntime = Runtime(protocol);
        const ProtocolCore = Core(protocol);
        const queue_end = std.math.maxInt(u32);
        const queue_none = queue_end - 1;

        const Pending = struct {
            generation: u32 = 0,
            next: u32 = queue_none,
        };

        runtime: *ServerRuntime,
        pending_storage: []Pending,
        pending_head: u32 = queue_end,
        pending_tail: u32 = queue_end,
        display_context: ?*anyopaque,

        pub const Progress = struct {
            completions: usize = 0,
            accepted: usize = 0,
            requests: usize = 0,
            protocol_errors: usize = 0,
            destroyed: usize = 0,
            prepared: usize = 0,
            pending: bool = false,

            fn merge(progress: *Progress, other: Progress) void {
                progress.completions += other.completions;
                progress.accepted += other.accepted;
                progress.requests += other.requests;
                progress.protocol_errors += other.protocol_errors;
                progress.destroyed += other.destroyed;
                progress.prepared += other.prepared;
                progress.pending = other.pending;
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            runtime: *ServerRuntime,
            display_context: ?*anyopaque,
        ) !Self {
            const storage = try allocator.alloc(Pending, runtime.clients.reactor.actor_storage.len);
            @memset(storage, .{});
            return .{
                .runtime = runtime,
                .pending_storage = storage,
                .display_context = display_context,
            };
        }

        pub fn deinit(driver: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(driver.pending_head == queue_end);
            std.debug.assert(driver.pending_tail == queue_end);
            allocator.free(driver.pending_storage);
            driver.* = undefined;
        }

        /// Marks a peer whose queued output or closing state should be prepared
        /// during the next batch. Repeated scheduling occupies one FIFO node.
        pub fn schedule(driver: *Self, peer: io_uring.Peer) !bool {
            _ = try driver.runtime.clients.get(peer);
            const node = &driver.pending_storage[peer.slot];
            if (node.next != queue_none) {
                if (node.generation != peer.generation) return error.StaleHandle;
                return false;
            }
            node.* = .{ .generation = peer.generation, .next = queue_end };
            if (driver.pending_tail == queue_end) {
                driver.pending_head = peer.slot;
            } else {
                driver.pending_storage[driver.pending_tail].next = peer.slot;
            }
            driver.pending_tail = peer.slot;
            return true;
        }

        /// Processes Wayring CQEs and prepares all resulting socket work without
        /// submitting the ring. On a borrowed ring, filter unrelated CQEs before
        /// passing the batch. Call `prepare` again after submission while
        /// `Progress.pending` is true.
        pub fn dispatch(
            driver: *Self,
            completions: []const std.os.linux.io_uring_cqe,
            handler: anytype,
        ) !Progress {
            var progress: Progress = .{};
            for (completions) |completion| {
                try driver.complete(completion, handler, &progress);
                progress.completions += 1;
            }
            progress.merge(try driver.prepare(handler));
            return progress;
        }

        /// Prepares queued sends, close cancellation, destruction, and deferred
        /// receives until the SQ fills or no work remains. This never submits.
        pub fn prepare(driver: *Self, handler: anytype) !Progress {
            var progress: Progress = .{};
            const reactor = driver.runtime.clients.reactor;
            while (driver.pending_head != queue_end) {
                const slot = driver.pending_head;
                const node = &driver.pending_storage[slot];
                const peer: io_uring.Peer = .{
                    .slot = @intCast(slot),
                    .generation = node.generation,
                };
                const actor = reactor.getActor(peer) catch {
                    driver.popPending();
                    continue;
                };

                if (actor.lifecycle == .closing and actor.canDeinit()) {
                    driver.popPending();
                    if (@hasDecl(@TypeOf(handler.*), "disconnected"))
                        handler.disconnected(peer);
                    try driver.runtime.destroyClient(peer);
                    progress.destroyed += 1;
                    continue;
                }

                if (actor.lifecycle == .closing) {
                    if (!actor.cancel_requested) {
                        const queued = reactor.prepareClose(peer) catch |err| {
                            if (err == error.SubmissionQueueFull) break;
                            return err;
                        };
                        if (queued) progress.prepared += 1;
                    }
                    driver.popPending();
                    continue;
                }

                if (actor.transmit.queuedBytes() != 0 and
                    !actor.transmit.sendActive())
                {
                    reactor.prepareSend(peer) catch |err| {
                        if (err == error.SubmissionQueueFull) break;
                        return err;
                    };
                    progress.prepared += 1;
                }
                driver.popPending();
            }

            progress.prepared += try reactor.prepareDeferredReceives();
            progress.pending = driver.pending_head != queue_end or
                reactor.deferredReceivesPending();
            return progress;
        }

        fn complete(
            driver: *Self,
            completion: std.os.linux.io_uring_cqe,
            handler: anytype,
            progress: *Progress,
        ) !void {
            const reactor = driver.runtime.clients.reactor;
            switch (reactor.route(&driver.runtime.endpoint.listener, completion) orelse
                return error.InvalidCompletion) {
                .listener => {
                    if (try driver.runtime.completeListener(
                        completion,
                        driver.display_context,
                    )) |peer| {
                        progress.accepted += 1;
                        progress.prepared += 1;
                        if (@hasDecl(@TypeOf(handler.*), "connected"))
                            handler.connected(peer);
                        _ = try driver.schedule(peer);
                    }
                },
                .connection => |routed| {
                    const peer = reactor.routedPeer(routed);
                    const actor = try reactor.getActor(peer);
                    const event = actor.completeRouted(routed.operation, completion) catch |err| {
                        if (err == error.IoFailure and actor.lifecycle == .closing) {
                            _ = try driver.schedule(peer);
                            return;
                        }
                        return err;
                    };
                    switch (event) {
                        .received => {
                            var context = RequestContext(@TypeOf(handler)){
                                .handler = handler,
                                .peer = peer,
                            };
                            const result = try ProtocolCore.receivedRequestsReactor(
                                actor,
                                &(try driver.runtime.clients.get(peer)).namespace,
                                reactor,
                                peer,
                                completion,
                                &context,
                            );
                            switch (result) {
                                .dispatched => |count| progress.requests += count,
                                .terminal => |failure| {
                                    progress.requests += failure.dispatched;
                                    if (failure.cause != error.Disconnected) {
                                        progress.protocol_errors += 1;
                                        if (@hasDecl(@TypeOf(handler.*), "protocolError"))
                                            handler.protocolError(peer, failure);
                                    }
                                },
                            }
                            if (actor.lifecycle == .open and !actor.receive_active)
                                _ = try reactor.deferReceive(peer);
                            _ = try driver.schedule(peer);
                        },
                        .sent, .disconnected, .receive_stopped, .send_stopped, .cancel_complete => _ = try driver.schedule(peer),
                        .buffers_exhausted => {
                            if (actor.lifecycle == .open)
                                _ = try reactor.deferReceive(peer);
                            _ = try driver.schedule(peer);
                        },
                    }
                },
            }
        }

        fn popPending(driver: *Self) void {
            const slot = driver.pending_head;
            const node = &driver.pending_storage[slot];
            driver.pending_head = node.next;
            if (driver.pending_head == queue_end) driver.pending_tail = queue_end;
            node.* = .{};
        }

        fn RequestContext(comptime Handler: type) type {
            return struct {
                handler: Handler,
                peer: io_uring.Peer,

                pub fn request(
                    context: *@This(),
                    target: objects.Dispatch,
                    message: wire.Message,
                    fds: *ancillary.FdQueue,
                ) !@import("dispatch.zig").Control {
                    return context.handler.request(context.peer, target, message, fds);
                }
            };
        }
    };
}
