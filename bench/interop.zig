const std = @import("std");
const wayring = @import("wayring");
const core_protocol = @import("core_protocol");
const standard_protocol = @import("standard_protocol");
const benchmark_protocol = @import("benchmark_protocol");

const ffi = @cImport({
    @cInclude("benchmark.h");
    @cInclude("xdg-interop.h");
    @cInclude("stdio.h");
});
const c = std.c;
const linux = std.os.linux;
const ClientCore = wayring.client.Core(core_protocol);
const ClientConnection = wayring.client.Connection(core_protocol);
const ServerCore = wayring.server.Core(core_protocol);
const ServerRuntime = wayring.server.Runtime(core_protocol);
const Benchmark = benchmark_protocol.wp_wayring_benchmark_v1;
const XdgServerCore = wayring.server.Core(standard_protocol);
const XdgServerRuntime = wayring.server.Runtime(standard_protocol);
const XdgClientCore = wayring.client.Core(standard_protocol);
const XdgClientConnection = wayring.client.Connection(standard_protocol);

const ProtocolInterop = enum { xdg, shm, dmabuf };
const drm_format_argb8888: u32 = 0x34325241;
const drm_format_modifier_invalid_hi: u32 = 0x00ffffff;
const drm_format_modifier_invalid_lo: u32 = 0xffffffff;

const Options = struct {
    messages: u64 = 1_000_000,
    batch: u32 = 256,
    warmup: u64 = 100_000,
    mode: enum {
        libwayland_client,
        libwayland_server,
        xdg_libwayland_client,
        xdg_libwayland_server,
        shm_libwayland_client,
        shm_libwayland_server,
        dmabuf_libwayland_client,
    } = .libwayland_client,
    latency: bool = false,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    const options = try parseOptions(init.args);
    return switch (options.mode) {
        .libwayland_client => wayringServer(options),
        .libwayland_server => wayringClient(options),
        .xdg_libwayland_client => wayringProtocolServer(.xdg),
        .xdg_libwayland_server => wayringXdgClient(),
        .shm_libwayland_client => wayringProtocolServer(.shm),
        .shm_libwayland_server => wayringShmClient(),
        .dmabuf_libwayland_client => wayringProtocolServer(.dmabuf),
    };
}

fn wayringServer(options: Options) !u8 {
    var path_storage: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "/tmp/wayring-interop-{d}",
        .{linux.getpid()},
    );
    wayring.unix_socket.unlink(path) catch |err| if (err != error.NotFound) return err;
    defer wayring.unix_socket.unlink(path) catch {};
    const listener_fd = try wayring.unix_socket.listen(path, 1);
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = linux.close(listener_fd);
        const connected_fd = wayring.unix_socket.connect(path) catch c._exit(1);
        const c_options = cOptions(options);
        var result: ffi.struct_benchmark_result = undefined;
        const status = ffi.benchmark_client_fd(connected_fd, &c_options, &result);
        if (status == 0 and result.messages == options.messages) {
            if (options.latency) {
                _ = c.printf(
                    "server=wayring client=libwayland latency_scope=round_trip rounds=%llu mean_ns=%llu p50_ns=%llu p95_ns=%llu p99_ns=%llu max_ns=%llu\n",
                    options.messages,
                    result.mean_ns,
                    result.p50_ns,
                    result.p95_ns,
                    result.p99_ns,
                    result.max_ns,
                );
            } else {
                _ = c.printf(
                    "server=wayring client=libwayland messages=%llu batch=%u elapsed_ns=%llu messages_per_second=%.0f\n",
                    options.messages,
                    options.batch,
                    result.elapsed_ns,
                    @as(f64, @floatFromInt(options.messages)) * @as(f64, std.time.ns_per_s) /
                        @as(f64, @floatFromInt(result.elapsed_ns)),
                );
            }
            _ = ffi.fflush(null);
        } else if (status == 0) {
            c._exit(1);
        }
        c._exit(status);
    }

    const allocator = std.heap.c_allocator;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .max_connections = 1,
        .receive_buffer_size = 64 * 1024,
        .receive_buffer_count = 8,
        .receive_control_capacity = 256,
        .fragment_block_size = wayring.wire.max_message_len,
        .fragment_block_count = 2,
        .transmit_block_size = 4096,
        .transmit_block_count = 4,
        .descriptor_count = 16,
        .send_descriptor_capacity = 8,
    });
    var runtime = try ServerRuntime.init(allocator, &reactor, listener_fd, .{
        .actor = .{
            .received_fd_budget = 8,
            .transmit_byte_budget = 16 * 1024,
            .transmit_fd_budget = 8,
        },
        .object_capacity = 8,
        .object_quota = 8,
        .buckets_per_client = 16,
        .max_globals = 1,
        .registry_capacity = 8,
    });
    _ = try runtime.globals.add(&Benchmark.info, 1, null);
    try runtime.prepareAccept();
    _ = try reactor.ring.submit();
    const accept_completion = try reactor.ring.copy_cqe();
    switch (reactor.route(&runtime.endpoint.listener, accept_completion) orelse
        return error.InvalidCompletion) {
        .listener => {},
        .connection => return error.InvalidCompletion,
    }
    const peer = (try runtime.completeListener(accept_completion, null)) orelse
        return error.InvalidCompletion;
    const actor = try reactor.getActor(peer);
    var handler: ServerHandler = .{
        .runtime = &runtime,
        .peer = peer,
        .objects = try runtime.clients.get(peer),
        .globals = &runtime.globals,
        .queue = &actor.transmit,
        .warmup = options.warmup,
        .target = options.warmup + options.messages,
        .latency = options.latency,
    };
    _ = try reactor.ring.submit();
    while (handler.received < handler.target or
        actor.transmit.queuedBytes() != 0 or actor.transmit.sendActive())
    {
        const completion = try reactor.ring.copy_cqe();
        const routed = switch (reactor.route(&runtime.endpoint.listener, completion) orelse
            return error.InvalidCompletion) {
            .listener => {
                if (try runtime.completeListener(completion, null) != null)
                    return error.UnexpectedClient;
                continue;
            },
            .connection => |routed| routed,
        };
        const event = try actor.completeRouted(routed.operation, completion);
        var prepared = false;
        switch (event) {
            .received => {
                switch (try ServerCore.receivedRequests(
                    actor,
                    &handler.objects.namespace,
                    try reactor.getReceiver(peer),
                    completion,
                    &handler,
                )) {
                    .dispatched => {},
                    .terminal => |failure| return failure.cause,
                }
                if (!actor.receive_active) {
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
            else => return error.InvalidCompletion,
        }
        if (actor.transmit.queuedBytes() > 0 and !actor.transmit.sendActive()) {
            try reactor.prepareSend(peer);
            prepared = true;
        }
        if (prepared) _ = try reactor.ring.submit();
    }
    _ = try runtime.prepareEndpointClose();
    _ = try runtime.clients.prepareClose(peer);
    _ = try reactor.ring.submit();
    while (!runtime.endpoint.listener.canDeinit() or !actor.canDeinit()) {
        const completion = try reactor.ring.copy_cqe();
        switch (reactor.route(&runtime.endpoint.listener, completion) orelse
            return error.InvalidCompletion) {
            .listener => if (try runtime.completeListener(completion, null) != null)
                return error.UnexpectedClient,
            .connection => |routed| {
                const event = try actor.completeRouted(routed.operation, completion);
                switch (event) {
                    .received => try (try reactor.getReceiver(peer)).buffers.put(completion),
                    .receive_stopped, .buffers_exhausted, .cancel_complete, .disconnected => {},
                    else => return error.InvalidCompletion,
                }
            },
        }
    }
    try runtime.destroyClient(peer);
    try runtime.deinit(allocator);
    reactor.deinit(allocator);
    return waitChild(child);
}

const ServerHandler = struct {
    runtime: *ServerRuntime,
    peer: wayring.io_uring.Peer,
    objects: *wayring.objects.SharedServerObjects,
    globals: *wayring.server.Globals,
    queue: *wayring.tx.Queue,
    warmup: u64,
    target: u64,
    latency: bool,
    received: u64 = 0,

    pub fn request(
        handler: *ServerHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ServerCore.Display.info) {
            const action = try handler.runtime.decodeDisplayRequest(
                handler.peer,
                message,
                fds,
                null,
            );
            switch (action) {
                .sync => |callback| try ServerCore.completeSync(
                    handler.objects,
                    handler.queue,
                    callback,
                    0,
                ),
                .get_registry => while (true) switch (try handler.runtime.publishNext()) {
                    .sent => {},
                    .blocked => return error.ByteBudgetExceeded,
                    .complete => break,
                },
            }
        } else if (target.object.interface == &ServerCore.Registry.info) {
            const handle = handler.objects.namespace.lookupHandle(message.header.object_id) orelse
                return error.UnknownObject;
            const registry_request = try ServerCore.decodeRegistryRequest(
                handler.objects,
                handle,
                message,
                fds,
            );
            _ = try ServerCore.bindGlobal(handler.objects, handler.globals, registry_request);
        } else if (target.object.interface == &Benchmark.info) {
            const decoded = try wayring.server.decodeRequest(
                Benchmark,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .ping => |ping| {
                    handler.received += 1;
                    if (handler.latency or handler.received == handler.warmup or
                        handler.received == handler.target)
                    {
                        try wayring.server.sendEvent(
                            core_protocol,
                            Benchmark,
                            handler.objects,
                            handler.queue,
                            decoded.handle,
                            .{ .pong = .{ .sequence = ping.sequence } },
                        );
                    }
                },
                .ping_fd => |ping| {
                    const flags = linux.fcntl(ping.descriptor, linux.F.GETFD, 0);
                    if (linux.errno(flags) != .SUCCESS or flags & linux.FD_CLOEXEC == 0) {
                        _ = linux.close(ping.descriptor);
                        return error.InvalidDescriptor;
                    }
                    wayring.server.sendEvent(
                        core_protocol,
                        Benchmark,
                        handler.objects,
                        handler.queue,
                        decoded.handle,
                        .{ .pong_fd = .{
                            .sequence = ping.sequence,
                            .descriptor = ping.descriptor,
                        } },
                    ) catch |err| {
                        _ = linux.close(ping.descriptor);
                        return err;
                    };
                },
            }
            try decoded.finish(core_protocol, handler.objects, handler.queue);
        } else return error.UnexpectedRequest;
        return .continue_dispatch;
    }
};

fn wayringProtocolServer(kind: ProtocolInterop) !u8 {
    var path_storage: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "/tmp/wayring-{s}-interop-{d}",
        .{ @tagName(kind), linux.getpid() },
    );
    wayring.unix_socket.unlink(path) catch |err| if (err != error.NotFound) return err;
    defer wayring.unix_socket.unlink(path) catch {};
    const listener_fd = try wayring.unix_socket.listen(path, 1);
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = linux.close(listener_fd);
        const connected_fd = wayring.unix_socket.connect(path) catch c._exit(1);
        c._exit(switch (kind) {
            .xdg => ffi.xdg_client_fd(connected_fd),
            .shm => ffi.shm_client_fd(connected_fd),
            .dmabuf => ffi.dmabuf_client_fd(connected_fd),
        });
    }

    const allocator = std.heap.c_allocator;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .max_connections = 1,
        .receive_buffer_size = 64 * 1024,
        .receive_buffer_count = 8,
        .receive_control_capacity = 256,
        .fragment_block_size = wayring.wire.max_message_len,
        .fragment_block_count = 2,
        .transmit_block_size = 4096,
        .transmit_block_count = 4,
        .descriptor_count = 8,
        .send_descriptor_capacity = 4,
    });
    var runtime = try XdgServerRuntime.init(allocator, &reactor, listener_fd, .{
        .actor = .{
            .received_fd_budget = 4,
            .transmit_byte_budget = 16 * 1024,
            .transmit_fd_budget = 4,
        },
        .object_capacity = 16,
        .object_quota = 16,
        .buckets_per_client = 32,
        .max_globals = 2,
        .registry_capacity = 2,
    });
    switch (kind) {
        .xdg => {
            _ = try runtime.globals.add(&standard_protocol.wl_compositor.info, 4, null);
            _ = try runtime.globals.add(&standard_protocol.xdg_wm_base.info, 5, null);
        },
        .shm => _ = try runtime.globals.add(&standard_protocol.wl_shm.info, 1, null),
        .dmabuf => _ = try runtime.globals.add(
            &standard_protocol.zwp_linux_dmabuf_v1.info,
            3,
            null,
        ),
    }
    try runtime.prepareAccept();
    _ = try reactor.ring.submit();
    const accept_completion = try reactor.ring.copy_cqe();
    switch (reactor.route(&runtime.endpoint.listener, accept_completion) orelse
        return error.InvalidCompletion) {
        .listener => {},
        .connection => return error.InvalidCompletion,
    }
    const peer = (try runtime.completeListener(accept_completion, null)) orelse
        return error.InvalidCompletion;
    const actor = try reactor.getActor(peer);
    var handler: ProtocolServerHandler = .{
        .runtime = &runtime,
        .peer = peer,
        .objects = try runtime.clients.get(peer),
        .queue = &actor.transmit,
    };
    _ = try reactor.ring.submit();

    var disconnected = false;
    while (!disconnected) {
        const completion = try reactor.ring.copy_cqe();
        const routed = switch (reactor.route(&runtime.endpoint.listener, completion) orelse
            return error.InvalidCompletion) {
            .listener => {
                if (try runtime.completeListener(completion, null) != null)
                    return error.UnexpectedClient;
                continue;
            },
            .connection => |value| value,
        };
        const event = actor.completeRouted(routed.operation, completion) catch |err| {
            if (err == error.IoFailure and actor.lifecycle == .closing) {
                disconnected = true;
                continue;
            }
            return err;
        };
        var prepared = false;
        switch (event) {
            .received => {
                switch (try XdgServerCore.receivedRequests(
                    actor,
                    &handler.objects.namespace,
                    try reactor.getReceiver(peer),
                    completion,
                    &handler,
                )) {
                    .dispatched => {},
                    .terminal => |failure| if (failure.cause == error.Disconnected) {
                        disconnected = true;
                    } else return failure.cause,
                }
                if (!disconnected and !actor.receive_active) {
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
            .disconnected => disconnected = true,
            else => return error.InvalidCompletion,
        }
        if (!disconnected and actor.transmit.queuedBytes() > 0 and !actor.transmit.sendActive()) {
            try reactor.prepareSend(peer);
            prepared = true;
        }
        if (prepared) _ = try reactor.ring.submit();
    }
    switch (kind) {
        .xdg => if (!handler.ponged or !handler.configured)
            return error.IncompleteInterop,
        .shm => if (!handler.pool_created or !handler.buffer_created or
            !handler.buffer_destroyed or !handler.pool_destroyed)
            return error.IncompleteInterop,
        .dmabuf => if (!handler.params_created or !handler.plane_added or
            !handler.dmabuf_buffer_created or !handler.buffer_destroyed or
            !handler.params_destroyed)
            return error.IncompleteInterop,
    }

    _ = try runtime.prepareEndpointClose();
    _ = try runtime.clients.prepareClose(peer);
    _ = try reactor.ring.submit();
    while (!runtime.endpoint.listener.canDeinit() or !actor.canDeinit()) {
        const completion = try reactor.ring.copy_cqe();
        switch (reactor.route(&runtime.endpoint.listener, completion) orelse
            return error.InvalidCompletion) {
            .listener => if (try runtime.completeListener(completion, null) != null)
                return error.UnexpectedClient,
            .connection => |routed| {
                const close_event = actor.completeRouted(routed.operation, completion) catch |err| {
                    if (err == error.IoFailure and actor.lifecycle == .closing) continue;
                    return err;
                };
                switch (close_event) {
                    .received => try (try reactor.getReceiver(peer)).buffers.put(completion),
                    .receive_stopped, .buffers_exhausted, .cancel_complete, .disconnected => {},
                    else => return error.InvalidCompletion,
                }
            },
        }
    }
    try runtime.destroyClient(peer);
    try runtime.deinit(allocator);
    reactor.deinit(allocator);
    return waitChild(child);
}

const ProtocolServerHandler = struct {
    runtime: *XdgServerRuntime,
    peer: wayring.io_uring.Peer,
    objects: *wayring.objects.SharedServerObjects,
    queue: *wayring.tx.Queue,
    ponged: bool = false,
    configured: bool = false,
    pool_created: bool = false,
    buffer_created: bool = false,
    buffer_destroyed: bool = false,
    pool_destroyed: bool = false,
    params_created: bool = false,
    plane_added: bool = false,
    dmabuf_buffer_created: bool = false,
    params_destroyed: bool = false,

    pub fn request(
        handler: *ProtocolServerHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const interface = target.object.interface;
        if (interface == &XdgServerCore.Display.info) {
            switch (try handler.runtime.decodeDisplayRequest(handler.peer, message, fds, null)) {
                .sync => |callback| try XdgServerCore.completeSync(
                    handler.objects,
                    handler.queue,
                    callback,
                    0,
                ),
                .get_registry => while (true) switch (try handler.runtime.publishNext()) {
                    .sent => {},
                    .blocked => return error.ByteBudgetExceeded,
                    .complete => break,
                },
            }
        } else if (interface == &XdgServerCore.Registry.info) {
            const registry = handler.objects.namespace.lookupHandle(message.header.object_id) orelse
                return error.UnknownObject;
            const registry_request = try XdgServerCore.decodeRegistryRequest(
                handler.objects,
                registry,
                message,
                fds,
            );
            const resource = try handler.runtime.bindGlobal(handler.peer, registry_request);
            const resource_interface = handler.objects.namespace.resolve(resource).?.interface;
            if (resource_interface == &standard_protocol.xdg_wm_base.info) {
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.xdg_wm_base,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .ping = .{ .serial = 41 } },
                );
            } else if (resource_interface == &standard_protocol.wl_shm.info) {
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_shm,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .format = .{ .format = .argb8888 } },
                );
            } else if (resource_interface == &standard_protocol.zwp_linux_dmabuf_v1.info) {
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.zwp_linux_dmabuf_v1,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .modifier = .{
                        .format = drm_format_argb8888,
                        .modifier_hi = drm_format_modifier_invalid_hi,
                        .modifier_lo = drm_format_modifier_invalid_lo,
                    } },
                );
            }
        } else if (interface == &standard_protocol.zwp_linux_dmabuf_v1.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.zwp_linux_dmabuf_v1,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .create_params => |value| {
                    _ = try standard_protocol.zwp_linux_dmabuf_v1.admit_create_params(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    );
                    handler.params_created = true;
                },
                .destroy => {},
                .get_default_feedback, .get_surface_feedback => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.zwp_linux_buffer_params_v1.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.zwp_linux_buffer_params_v1,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .add => |value| {
                    defer _ = linux.close(value.fd);
                    const flags = linux.fcntl(value.fd, linux.F.GETFD, 0);
                    if (linux.errno(flags) != .SUCCESS or flags & linux.FD_CLOEXEC == 0 or
                        value.plane_idx != 0 or value.offset != 0 or value.stride != 4 or
                        value.modifier_hi != drm_format_modifier_invalid_hi or
                        value.modifier_lo != drm_format_modifier_invalid_lo)
                        return error.InvalidDmabufPlane;
                    handler.plane_added = true;
                },
                .create_immed => |value| {
                    if (!handler.plane_added or value.width != 1 or value.height != 1 or
                        value.format != drm_format_argb8888 or value.flags.value != 0)
                        return error.InvalidDmabufBuffer;
                    _ = try standard_protocol.zwp_linux_buffer_params_v1.admit_create_immed(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    );
                    handler.dmabuf_buffer_created = true;
                },
                .destroy => handler.params_destroyed = handler.buffer_destroyed,
                .create => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_shm.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_shm,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .create_pool => |value| {
                    defer _ = linux.close(value.fd);
                    const flags = linux.fcntl(value.fd, linux.F.GETFD, 0);
                    if (linux.errno(flags) != .SUCCESS or flags & linux.FD_CLOEXEC == 0 or
                        value.size != 4096)
                        return error.InvalidShmPool;
                    _ = try standard_protocol.wl_shm.admit_create_pool(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    );
                    handler.pool_created = true;
                },
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_shm_pool.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_shm_pool,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .create_buffer => |value| {
                    if (value.offset != 0 or value.width != 1 or value.height != 1 or
                        value.stride != 4 or value.format.value !=
                        standard_protocol.wl_shm.format.argb8888.value)
                        return error.InvalidShmBuffer;
                    _ = try standard_protocol.wl_shm_pool.admit_create_buffer(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    );
                    handler.buffer_created = true;
                },
                .destroy => handler.pool_destroyed = handler.buffer_destroyed,
                .resize => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_buffer.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_buffer,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .destroy => handler.buffer_destroyed = true,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_compositor.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_compositor,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .create_surface => |value| _ = try standard_protocol.wl_compositor.admit_create_surface(
                    handler.objects,
                    decoded.handle,
                    value,
                    .{},
                ),
                .create_region => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.xdg_wm_base.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.xdg_wm_base,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .get_xdg_surface => |value| _ = try standard_protocol.xdg_wm_base.admit_get_xdg_surface(
                    handler.objects,
                    decoded.handle,
                    value,
                    .{},
                ),
                .pong => |value| {
                    if (value.serial != 41) return error.InvalidSerial;
                    handler.ponged = true;
                },
                .destroy => {},
                .create_positioner => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.xdg_surface.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.xdg_surface,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .get_toplevel => |value| {
                    const toplevel = (try standard_protocol.xdg_surface.admit_get_toplevel(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).id;
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.xdg_toplevel,
                        handler.objects,
                        handler.queue,
                        toplevel,
                        .{ .configure = .{ .width = 0, .height = 0, .states = &.{} } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.xdg_surface,
                        handler.objects,
                        handler.queue,
                        decoded.handle,
                        .{ .configure = .{ .serial = 77 } },
                    );
                },
                .ack_configure => |value| {
                    if (value.serial != 77) return error.InvalidSerial;
                    handler.configured = true;
                },
                .destroy, .set_window_geometry => {},
                .get_popup => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.xdg_toplevel.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.xdg_toplevel,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .destroy => {},
                else => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_surface.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_surface,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .commit, .destroy => {},
                else => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else return error.UnexpectedRequest;
        return .continue_dispatch;
    }
};

fn wayringXdgClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.xdg_server_fd(sockets[1]));
    }
    _ = c.close(sockets[1]);

    const allocator = std.heap.c_allocator;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .max_connections = 1,
        .receive_buffer_size = 64 * 1024,
        .receive_buffer_count = 8,
        .receive_control_capacity = 256,
        .fragment_block_size = wayring.wire.max_message_len,
        .fragment_block_count = 2,
        .transmit_block_size = 4096,
        .transmit_block_count = 4,
        .descriptor_count = 8,
        .send_descriptor_capacity = 4,
    });
    var connection = try XdgClientConnection.attach(
        allocator,
        &reactor,
        sockets[0],
        .{
            .received_fd_budget = 4,
            .transmit_byte_budget = 16 * 1024,
            .transmit_fd_budget = 4,
        },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    const peer = connection.peer;
    const actor = try connection.actor();
    const client_objects = &connection.objects;
    const registry = try XdgClientCore.getRegistry(client_objects, &actor.transmit, null);
    const callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    var handler: XdgClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.compositor == null or handler.wm_base == null or
        !handler.synced or !handler.deleted or !handler.pinged)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const surface = (try standard_protocol.wl_compositor.construct_create_surface(
        client_objects,
        &actor.transmit,
        handler.compositor.?,
        .{},
    )).id;
    const xdg_surface = (try standard_protocol.xdg_wm_base.construct_get_xdg_surface(
        client_objects,
        &actor.transmit,
        handler.wm_base.?,
        .{ .surface = surface.id },
    )).id;
    handler.xdg_surface = xdg_surface;
    handler.toplevel = (try standard_protocol.xdg_surface.construct_get_toplevel(
        client_objects,
        &actor.transmit,
        xdg_surface,
        .{},
    )).id;
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .commit = .{} },
    );
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.configured)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.synced or !handler.deleted or
        actor.transmit.queuedBytes() > 0 or actor.transmit.sendActive())
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.xdg_toplevel,
        client_objects,
        &actor.transmit,
        handler.toplevel.?,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.xdg_surface,
        client_objects,
        &actor.transmit,
        xdg_surface,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.xdg_wm_base,
        client_objects,
        &actor.transmit,
        handler.wm_base.?,
        .{ .destroy = .{} },
    );
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (actor.transmit.queuedBytes() > 0 or actor.transmit.sendActive())
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try (try connection.receiver()).stop(reactor.ring, reactor.slots, actor);
    try connection.deinit(allocator);
    reactor.deinit(allocator);
    return waitChild(child);
}

const XdgClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    xdg_surface: ?wayring.objects.Handle = null,
    toplevel: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    pinged: bool = false,
    configured: bool = false,

    pub fn event(
        handler: *XdgClientHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const interface = target.object.interface;
        if (interface == &XdgClientCore.Display.info) {
            switch (try XdgClientCore.decodeDisplayEvent(handler.objects, message, fds)) {
                .delete_id => |deleted| {
                    if (deleted.id == handler.callback.id) handler.deleted = true;
                },
                .@"error" => return error.ProtocolError,
            }
        } else if (interface == &XdgClientCore.Registry.info) {
            switch (try XdgClientCore.decodeRegistryEvent(
                handler.objects,
                handler.registry,
                message,
                fds,
            )) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, standard_protocol.wl_compositor.info.name)) {
                        handler.compositor = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_compositor.info,
                            @min(global.version, 4),
                            null,
                        );
                    } else if (std.mem.eql(
                        u8,
                        global.interface,
                        standard_protocol.xdg_wm_base.info.name,
                    )) {
                        handler.wm_base = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.xdg_wm_base.info,
                            @min(global.version, 5),
                            null,
                        );
                    }
                },
                .global_remove => {},
            }
        } else if (interface == &XdgClientCore.Callback.info) {
            _ = try XdgClientCore.decodeCallbackEvent(
                handler.objects,
                handler.callback,
                message,
                fds,
            );
            handler.synced = true;
        } else if (interface == &standard_protocol.xdg_wm_base.info) {
            const wm_base = handler.wm_base orelse return error.UnexpectedEvent;
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.xdg_wm_base,
                handler.objects,
                wm_base,
                message,
                fds,
            );
            const serial = switch (event_value) {
                .ping => |value| value.serial,
            };
            if (serial != 41) return error.InvalidSerial;
            try wayring.client.sendRequest(
                standard_protocol.xdg_wm_base,
                handler.objects,
                handler.queue,
                wm_base,
                .{ .pong = .{ .serial = serial } },
            );
            handler.pinged = true;
        } else if (interface == &standard_protocol.xdg_toplevel.info) {
            _ = try wayring.client.decodeEvent(
                standard_protocol.xdg_toplevel,
                handler.objects,
                handler.toplevel orelse return error.UnexpectedEvent,
                message,
                fds,
            );
        } else if (interface == &standard_protocol.xdg_surface.info) {
            const xdg_surface = handler.xdg_surface orelse return error.UnexpectedEvent;
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.xdg_surface,
                handler.objects,
                xdg_surface,
                message,
                fds,
            );
            const serial = switch (event_value) {
                .configure => |value| value.serial,
            };
            if (serial != 77) return error.InvalidSerial;
            try wayring.client.sendRequest(
                standard_protocol.xdg_surface,
                handler.objects,
                handler.queue,
                xdg_surface,
                .{ .ack_configure = .{ .serial = serial } },
            );
            handler.configured = true;
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn pumpProtocolClient(
    reactor: *wayring.io_uring.Reactor,
    peer: wayring.io_uring.Peer,
    client_objects: *wayring.objects.ClientObjects,
    handler: anytype,
) !void {
    const completion = try reactor.ring.copy_cqe();
    const routed = (reactor.route(null, completion) orelse
        return error.InvalidCompletion).connection;
    const actor = try reactor.getActor(peer);
    const event = try actor.completeRouted(routed.operation, completion);
    var prepared = false;
    switch (event) {
        .received => {
            switch (try XdgClientCore.receivedEvents(
                actor,
                &client_objects.namespace,
                try reactor.getReceiver(peer),
                completion,
                handler,
            )) {
                .dispatched => {},
                .terminal => |failure| return failure.cause,
            }
            if (!actor.receive_active) {
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
        else => return error.InvalidCompletion,
    }
    if (actor.transmit.queuedBytes() > 0 and !actor.transmit.sendActive()) {
        try reactor.prepareSend(peer);
        prepared = true;
    }
    if (prepared) _ = try reactor.ring.submit();
}

fn wayringShmClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.shm_server_fd(sockets[1]));
    }
    _ = c.close(sockets[1]);

    const allocator = std.heap.c_allocator;
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .max_connections = 1,
        .receive_buffer_size = 64 * 1024,
        .receive_buffer_count = 8,
        .receive_control_capacity = 256,
        .fragment_block_size = wayring.wire.max_message_len,
        .fragment_block_count = 2,
        .transmit_block_size = 4096,
        .transmit_block_count = 4,
        .descriptor_count = 8,
        .send_descriptor_capacity = 4,
    });
    var connection = try XdgClientConnection.attach(
        allocator,
        &reactor,
        sockets[0],
        .{
            .received_fd_budget = 4,
            .transmit_byte_budget = 16 * 1024,
            .transmit_fd_budget = 4,
        },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    const peer = connection.peer;
    const actor = try connection.actor();
    const client_objects = &connection.objects;
    const registry = try XdgClientCore.getRegistry(client_objects, &actor.transmit, null);
    const callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    var handler: ShmClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.shm == null or !handler.format_seen or
        !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const descriptor_result = linux.memfd_create("wayring-shm-interop", linux.MFD.CLOEXEC);
    if (linux.errno(descriptor_result) != .SUCCESS) return error.SystemCallFailed;
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    if (linux.errno(linux.ftruncate(descriptor, 4096)) != .SUCCESS) {
        _ = linux.close(descriptor);
        return error.SystemCallFailed;
    }
    const pool = standard_protocol.wl_shm.construct_create_pool(
        client_objects,
        &actor.transmit,
        handler.shm.?,
        .{ .fd = descriptor, .size = 4096 },
    ) catch |err| {
        _ = linux.close(descriptor);
        return err;
    };
    const buffer = (try standard_protocol.wl_shm_pool.construct_create_buffer(
        client_objects,
        &actor.transmit,
        pool.id,
        .{
            .offset = 0,
            .width = 1,
            .height = 1,
            .stride = 4,
            .format = .argb8888,
        },
    )).id;
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.wl_buffer,
        client_objects,
        &actor.transmit,
        buffer,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_shm_pool,
        client_objects,
        &actor.transmit,
        pool.id,
        .{ .destroy = .{} },
    );
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.synced or !handler.deleted or
        actor.transmit.queuedBytes() > 0 or actor.transmit.sendActive())
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try (try connection.receiver()).stop(reactor.ring, reactor.slots, actor);
    try connection.deinit(allocator);
    reactor.deinit(allocator);
    return waitChild(child);
}

const ShmClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    shm: ?wayring.objects.Handle = null,
    format_seen: bool = false,
    synced: bool = false,
    deleted: bool = false,

    pub fn event(
        handler: *ShmClientHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const interface = target.object.interface;
        if (interface == &XdgClientCore.Display.info) {
            switch (try XdgClientCore.decodeDisplayEvent(handler.objects, message, fds)) {
                .delete_id => |deleted| {
                    if (deleted.id == handler.callback.id) handler.deleted = true;
                },
                .@"error" => return error.ProtocolError,
            }
        } else if (interface == &XdgClientCore.Registry.info) {
            switch (try XdgClientCore.decodeRegistryEvent(
                handler.objects,
                handler.registry,
                message,
                fds,
            )) {
                .global => |global| if (std.mem.eql(
                    u8,
                    global.interface,
                    standard_protocol.wl_shm.info.name,
                )) {
                    handler.shm = try XdgClientCore.bind(
                        handler.objects,
                        handler.queue,
                        handler.registry,
                        global.name,
                        &standard_protocol.wl_shm.info,
                        @min(global.version, 1),
                        null,
                    );
                },
                .global_remove => {},
            }
        } else if (interface == &XdgClientCore.Callback.info) {
            _ = try XdgClientCore.decodeCallbackEvent(
                handler.objects,
                handler.callback,
                message,
                fds,
            );
            handler.synced = true;
        } else if (interface == &standard_protocol.wl_shm.info) {
            const shm_event = try wayring.client.decodeEvent(
                standard_protocol.wl_shm,
                handler.objects,
                handler.shm orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (shm_event) {
                .format => |value| {
                    if (value.format.value == standard_protocol.wl_shm.format.argb8888.value)
                        handler.format_seen = true;
                },
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn wayringClient(options: Options) !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        const c_options = cOptions(options);
        c._exit(ffi.benchmark_server(sockets[1], &c_options));
    }
    _ = c.close(sockets[1]);

    const allocator = std.heap.c_allocator;
    const batch_bytes = try std.math.mul(usize, options.batch, 12);
    const byte_budget = @max(@as(usize, 4096), batch_bytes);
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16 }, .{
        .max_connections = 1,
        .receive_buffer_size = 64 * 1024,
        .receive_buffer_count = 8,
        .receive_control_capacity = 256,
        .fragment_block_size = wayring.wire.max_message_len,
        .fragment_block_count = 2,
        .transmit_block_size = byte_budget,
        .transmit_block_count = 1,
        .descriptor_count = 8,
        .send_descriptor_capacity = 4,
    });
    var connection = try ClientConnection.attach(
        allocator,
        &reactor,
        sockets[0],
        .{
            .received_fd_budget = 4,
            .transmit_byte_budget = byte_budget,
            .transmit_fd_budget = 4,
        },
        .{ .max_objects = 8, .max_client_ids = 7 },
    );
    const peer = connection.peer;
    const actor = try connection.actor();
    const client_objects = &connection.objects;
    const registry = try ClientCore.getRegistry(client_objects, &actor.transmit, null);
    const callback = try ClientCore.sync(client_objects, &actor.transmit, null);
    var handler: ClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.benchmark == null or !handler.synced or !handler.deleted)
        try pumpClient(&reactor, peer, client_objects, &handler);
    while (actor.transmit.queuedBytes() > 0 or actor.transmit.sendActive())
        try pumpClient(&reactor, peer, client_objects, &handler);

    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(descriptor_result) != .SUCCESS) return error.SystemCallFailed;
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    wayring.client.sendRequest(
        Benchmark,
        client_objects,
        &actor.transmit,
        handler.benchmark.?,
        .{ .ping_fd = .{ .sequence = 0, .descriptor = descriptor } },
    ) catch |err| {
        _ = linux.close(descriptor);
        return err;
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.fd_valid or actor.transmit.queuedBytes() > 0 or actor.transmit.sendActive())
        try pumpClient(&reactor, peer, client_objects, &handler);

    if (options.latency) {
        try clientLatency(allocator, &reactor, peer, client_objects, &handler, options);
    } else {
        try clientPhase(&reactor, peer, client_objects, &handler, options.warmup, options.batch, 1);
        const start = try monotonicNs();
        try clientPhase(&reactor, peer, client_objects, &handler, options.messages, options.batch, 2);
        const elapsed = try monotonicNs() - start;
        _ = c.printf(
            "server=libwayland client=wayring messages=%llu batch=%u elapsed_ns=%llu messages_per_second=%.0f\n",
            options.messages,
            options.batch,
            elapsed,
            @as(f64, @floatFromInt(options.messages)) * @as(f64, std.time.ns_per_s) /
                @as(f64, @floatFromInt(elapsed)),
        );
    }

    try (try connection.receiver()).stop(reactor.ring, reactor.slots, actor);
    try connection.deinit(allocator);
    reactor.deinit(allocator);
    return waitChild(child);
}

const ClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    benchmark: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    pong: u32 = 0,
    fd_valid: bool = false,

    pub fn event(
        handler: *ClientHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Display.info) {
            const event_value = try ClientCore.decodeDisplayEvent(handler.objects, message, fds);
            switch (event_value) {
                .delete_id => |deleted| {
                    if (deleted.id == handler.callback.id) handler.deleted = true;
                },
                .@"error" => return error.ProtocolError,
            }
        } else if (target.object.interface == &ClientCore.Registry.info) {
            const event_value = try ClientCore.decodeRegistryEvent(
                handler.objects,
                handler.registry,
                message,
                fds,
            );
            switch (event_value) {
                .global => |global| if (std.mem.eql(u8, global.interface, Benchmark.info.name)) {
                    handler.benchmark = try ClientCore.bind(
                        handler.objects,
                        handler.queue,
                        handler.registry,
                        global.name,
                        &Benchmark.info,
                        @min(global.version, 1),
                        null,
                    );
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &ClientCore.Callback.info) {
            _ = try ClientCore.decodeCallbackEvent(
                handler.objects,
                handler.callback,
                message,
                fds,
            );
            handler.synced = true;
        } else if (target.object.interface == &Benchmark.info) {
            const benchmark = handler.benchmark orelse return error.UnexpectedEvent;
            const event_value = try wayring.client.decodeEvent(
                Benchmark,
                handler.objects,
                benchmark,
                message,
                fds,
            );
            handler.pong = switch (event_value) {
                .pong => |pong| pong.sequence,
                .pong_fd => |pong| blk: {
                    const flags = linux.fcntl(pong.descriptor, linux.F.GETFD, 0);
                    handler.fd_valid = pong.sequence == 0 and
                        linux.errno(flags) == .SUCCESS and flags & linux.FD_CLOEXEC != 0;
                    _ = linux.close(pong.descriptor);
                    break :blk handler.pong;
                },
            };
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn clientPhase(
    reactor: *wayring.io_uring.Reactor,
    peer: wayring.io_uring.Peer,
    client_objects: *wayring.objects.ClientObjects,
    handler: *ClientHandler,
    count: u64,
    batch: u32,
    sequence: u32,
) !void {
    var remaining = count;
    while (remaining > 0) {
        const chunk = @min(remaining, batch);
        for (0..chunk) |_| try wayring.client.sendRequest(
            Benchmark,
            client_objects,
            &(try reactor.getActor(peer)).transmit,
            handler.benchmark.?,
            .{ .ping = .{ .sequence = sequence } },
        );
        remaining -= chunk;
        const actor = try reactor.getActor(peer);
        if (!actor.transmit.sendActive()) {
            try reactor.prepareSend(peer);
            _ = try reactor.ring.submit();
        }
        while (actor.transmit.queuedBytes() > 0 or actor.transmit.sendActive())
            try pumpClient(reactor, peer, client_objects, handler);
    }
    while (handler.pong != sequence)
        try pumpClient(reactor, peer, client_objects, handler);
}

fn clientLatency(
    allocator: std.mem.Allocator,
    reactor: *wayring.io_uring.Reactor,
    peer: wayring.io_uring.Peer,
    client_objects: *wayring.objects.ClientObjects,
    handler: *ClientHandler,
    options: Options,
) !void {
    const samples = try allocator.alloc(u64, @intCast(options.messages));
    defer allocator.free(samples);
    for (0..options.warmup) |round| try clientPhase(
        reactor,
        peer,
        client_objects,
        handler,
        1,
        1,
        @intCast(round + 1),
    );
    var sum: u128 = 0;
    for (samples, 0..) |*sample, round| {
        const start = try monotonicNs();
        try clientPhase(
            reactor,
            peer,
            client_objects,
            handler,
            1,
            1,
            @intCast(options.warmup + round + 1),
        );
        sample.* = try monotonicNs() - start;
        sum += sample.*;
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    _ = c.printf(
        "server=libwayland client=wayring latency_scope=round_trip rounds=%llu mean_ns=%.0f p50_ns=%llu p95_ns=%llu p99_ns=%llu max_ns=%llu\n",
        options.messages,
        @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(options.messages)),
        percentile(samples, 50),
        percentile(samples, 95),
        percentile(samples, 99),
        samples[samples.len - 1],
    );
}

fn percentile(samples: []const u64, percent: u64) u64 {
    const rank = (samples.len * percent + 99) / 100;
    return samples[if (rank == 0) 0 else rank - 1];
}

fn pumpClient(
    reactor: *wayring.io_uring.Reactor,
    peer: wayring.io_uring.Peer,
    client_objects: *wayring.objects.ClientObjects,
    handler: *ClientHandler,
) !void {
    const completion = try reactor.ring.copy_cqe();
    const routed = (reactor.route(null, completion) orelse
        return error.InvalidCompletion).connection;
    const actor = try reactor.getActor(peer);
    const event = try actor.completeRouted(routed.operation, completion);
    var prepared = false;
    switch (event) {
        .received => {
            switch (try ClientCore.receivedEvents(
                actor,
                &client_objects.namespace,
                try reactor.getReceiver(peer),
                completion,
                handler,
            )) {
                .dispatched => {},
                .terminal => |failure| return failure.cause,
            }
            if (!actor.receive_active) {
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
        else => return error.InvalidCompletion,
    }
    if (actor.transmit.queuedBytes() > 0 and !actor.transmit.sendActive()) {
        try reactor.prepareSend(peer);
        prepared = true;
    }
    if (prepared) _ = try reactor.ring.submit();
}

fn cOptions(options: Options) ffi.struct_benchmark_options {
    return .{
        .warmup = options.warmup,
        .messages = options.messages,
        .batch = options.batch,
        .objects = 1,
        .latency = @intFromBool(options.latency),
    };
}

fn waitChild(child: c.pid_t) !u8 {
    var status: c_int = 0;
    if (c.waitpid(child, &status, 0) != child or
        !c.W.IFEXITED(@bitCast(status)) or c.W.EXITSTATUS(@bitCast(status)) != 0)
        return error.PeerFailed;
    return 0;
}

fn monotonicNs() !u64 {
    var value: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC_RAW, &value) != 0) return error.SystemCallFailed;
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}

fn parseOptions(args: std.process.Args) !Options {
    var options: Options = .{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.skip();
    if (iterator.next()) |value| options.messages = try std.fmt.parseUnsigned(u64, value, 10);
    if (iterator.next()) |value| options.batch = try std.fmt.parseUnsigned(u32, value, 10);
    if (iterator.next()) |value| options.warmup = try std.fmt.parseUnsigned(u64, value, 10);
    if (iterator.next()) |value| {
        if (std.mem.eql(u8, value, "libwayland-client"))
            options.mode = .libwayland_client
        else if (std.mem.eql(u8, value, "libwayland-server"))
            options.mode = .libwayland_server
        else if (std.mem.eql(u8, value, "libwayland-client-latency")) {
            options.mode = .libwayland_client;
            options.latency = true;
        } else if (std.mem.eql(u8, value, "libwayland-server-latency")) {
            options.mode = .libwayland_server;
            options.latency = true;
        } else if (std.mem.eql(u8, value, "xdg-libwayland-client")) {
            options.mode = .xdg_libwayland_client;
        } else if (std.mem.eql(u8, value, "xdg-libwayland-server")) {
            options.mode = .xdg_libwayland_server;
        } else if (std.mem.eql(u8, value, "shm-libwayland-client")) {
            options.mode = .shm_libwayland_client;
        } else if (std.mem.eql(u8, value, "shm-libwayland-server")) {
            options.mode = .shm_libwayland_server;
        } else if (std.mem.eql(u8, value, "dmabuf-libwayland-client")) {
            options.mode = .dmabuf_libwayland_client;
        } else return error.InvalidMode;
    }
    if (iterator.next() != null or options.messages == 0 or options.batch == 0 or
        options.warmup == 0 or options.warmup > std.math.maxInt(u64) - options.messages or
        (options.latency and options.warmup + options.messages > std.math.maxInt(u32)))
        return error.InvalidArguments;
    return options;
}
