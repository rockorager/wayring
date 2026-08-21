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

const ProtocolInterop = enum { xdg, shm, dmabuf, data_device, output, pointer, keyboard, touch };
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
        dmabuf_libwayland_server,
        data_device_libwayland_client,
        data_device_libwayland_server,
        output_libwayland_client,
        output_libwayland_server,
        pointer_libwayland_client,
        pointer_libwayland_server,
        keyboard_libwayland_client,
        keyboard_libwayland_server,
        touch_libwayland_client,
        touch_libwayland_server,
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
        .dmabuf_libwayland_server => wayringDmabufClient(),
        .data_device_libwayland_client => wayringProtocolServer(.data_device),
        .data_device_libwayland_server => wayringDataDeviceClient(),
        .output_libwayland_client => wayringProtocolServer(.output),
        .output_libwayland_server => wayringOutputClient(),
        .pointer_libwayland_client => wayringProtocolServer(.pointer),
        .pointer_libwayland_server => wayringPointerClient(),
        .keyboard_libwayland_client => wayringProtocolServer(.keyboard),
        .keyboard_libwayland_server => wayringKeyboardClient(),
        .touch_libwayland_client => wayringProtocolServer(.touch),
        .touch_libwayland_server => wayringTouchClient(),
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
            .data_device => ffi.data_device_client_fd(connected_fd),
            .output => ffi.output_client_fd(connected_fd),
            .pointer => ffi.pointer_client_fd(connected_fd),
            .keyboard => ffi.keyboard_client_fd(connected_fd),
            .touch => ffi.touch_client_fd(connected_fd),
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
        .object_capacity = 20,
        .object_quota = 20,
        .buckets_per_client = 32,
        .max_globals = 3,
        .registry_capacity = 2,
    });
    switch (kind) {
        .xdg => {
            _ = try runtime.globals.add(&standard_protocol.wl_compositor.info, 4, null);
            _ = try runtime.globals.add(&standard_protocol.xdg_wm_base.info, 5, null);
            _ = try runtime.globals.add(&standard_protocol.wp_presentation.info, 1, null);
        },
        .shm => {
            _ = try runtime.globals.add(&standard_protocol.wl_shm.info, 1, null);
            _ = try runtime.globals.add(&standard_protocol.wl_compositor.info, 4, null);
        },
        .dmabuf => _ = try runtime.globals.add(
            &standard_protocol.zwp_linux_dmabuf_v1.info,
            3,
            null,
        ),
        .data_device => {
            _ = try runtime.globals.add(&standard_protocol.wl_seat.info, 7, null);
            _ = try runtime.globals.add(&standard_protocol.wl_data_device_manager.info, 3, null);
        },
        .output => _ = try runtime.globals.add(&standard_protocol.wl_output.info, 4, null),
        .pointer => {
            _ = try runtime.globals.add(&standard_protocol.wl_compositor.info, 4, null);
            _ = try runtime.globals.add(&standard_protocol.wl_seat.info, 8, null);
        },
        .keyboard => {
            _ = try runtime.globals.add(&standard_protocol.wl_compositor.info, 4, null);
            _ = try runtime.globals.add(&standard_protocol.wl_seat.info, 8, null);
        },
        .touch => {
            _ = try runtime.globals.add(&standard_protocol.wl_compositor.info, 4, null);
            _ = try runtime.globals.add(&standard_protocol.wl_seat.info, 8, null);
        },
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
        .kind = kind,
        .runtime = &runtime,
        .peer = peer,
        .objects = try runtime.clients.get(peer),
        .queue = &actor.transmit,
    };
    defer {
        if (handler.selection_read_fd >= 0) _ = linux.close(handler.selection_read_fd);
    }
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
        .xdg => if (!handler.ponged or !handler.configured or !handler.clock_seen or
            !handler.feedback_presented or !handler.feedback_discarded or
            handler.feedback_count != 2)
            return error.IncompleteInterop,
        .shm => if (!handler.pool_created or !handler.buffer_created or
            !handler.surface_created or !handler.surface_committed or
            !handler.buffer_released or !handler.frame_completed or
            !handler.surface_destroyed or !handler.buffer_destroyed or
            !handler.pool_destroyed)
            return error.IncompleteInterop,
        .dmabuf => if (!handler.params_created or !handler.plane_added or
            !handler.dmabuf_buffer_created or !handler.buffer_destroyed or
            !handler.params_destroyed or !handler.async_buffer_created or
            !handler.create_failed or handler.params_created_count != 3 or
            handler.plane_added_count != 3 or handler.buffer_destroyed_count != 2 or
            handler.params_destroyed_count != 3)
            return error.IncompleteInterop,
        .data_device => if (!handler.data_source_created or !handler.data_device_created or
            !handler.mime_offered or !handler.selection_set or !handler.selection_sent or
            !handler.data_source_destroyed or !handler.data_device_released or
            !handler.seat_released)
            return error.IncompleteInterop,
        .output => if (!handler.output_sent or !handler.output_released)
            return error.IncompleteInterop,
        .pointer => if (!handler.seat_advertised or !handler.pointer_created or
            !handler.pointer_sent or !handler.pointer_released or !handler.surface_destroyed or
            !handler.seat_released)
            return error.IncompleteInterop,
        .keyboard => if (!handler.seat_advertised or !handler.keyboard_created or
            !handler.keyboard_sent or !handler.keyboard_released or !handler.surface_destroyed or
            !handler.seat_released)
            return error.IncompleteInterop,
        .touch => if (!handler.seat_advertised or !handler.touch_created or
            !handler.touch_sent or !handler.touch_released or !handler.surface_destroyed or
            !handler.seat_released)
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
    kind: ProtocolInterop,
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
    surface_created: bool = false,
    surface_committed: bool = false,
    buffer_released: bool = false,
    frame_completed: bool = false,
    buffer: ?wayring.objects.Handle = null,
    frame_callback: ?wayring.objects.Handle = null,
    params_created: bool = false,
    plane_added: bool = false,
    dmabuf_buffer_created: bool = false,
    params_destroyed: bool = false,
    async_buffer_created: bool = false,
    create_failed: bool = false,
    params_created_count: usize = 0,
    plane_added_count: usize = 0,
    buffer_destroyed_count: usize = 0,
    params_destroyed_count: usize = 0,
    clock_seen: bool = false,
    feedback_presented: bool = false,
    feedback_discarded: bool = false,
    feedback_count: usize = 0,
    data_source_created: bool = false,
    data_device_created: bool = false,
    mime_offered: bool = false,
    selection_set: bool = false,
    selection_sent: bool = false,
    data_source_destroyed: bool = false,
    data_device_released: bool = false,
    seat_released: bool = false,
    selection_read_fd: linux.fd_t = -1,
    output_sent: bool = false,
    output_released: bool = false,
    seat_advertised: bool = false,
    pointer_created: bool = false,
    pointer_sent: bool = false,
    pointer_released: bool = false,
    keyboard_created: bool = false,
    keyboard_sent: bool = false,
    keyboard_released: bool = false,
    touch_created: bool = false,
    touch_sent: bool = false,
    touch_released: bool = false,
    surface: ?wayring.objects.Handle = null,
    surface_destroyed: bool = false,

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
            } else if (resource_interface == &standard_protocol.wp_presentation.info) {
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wp_presentation,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .clock_id = .{ .clk_id = 1 } },
                );
                handler.clock_seen = true;
            } else if (resource_interface == &standard_protocol.wl_output.info) {
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_output,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .geometry = .{
                        .x = -10,
                        .y = 20,
                        .physical_width = 600,
                        .physical_height = 340,
                        .subpixel = .horizontal_rgb,
                        .make = "Wayring",
                        .model = "Virtual-1",
                        .transform = .@"90",
                    } },
                );
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_output,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .mode = .{
                        .flags = .fromInt(3),
                        .width = 1920,
                        .height = 1080,
                        .refresh = 60_000,
                    } },
                );
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_output,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .scale = .{ .factor = 2 } },
                );
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_output,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .name = .{ .name = "WL-1" } },
                );
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_output,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .description = .{ .description = "Wayring virtual output" } },
                );
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_output,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .done = .{} },
                );
                handler.output_sent = true;
            } else if (resource_interface == &standard_protocol.wl_seat.info and
                (handler.kind == .pointer or handler.kind == .keyboard or handler.kind == .touch))
            {
                const capability = switch (handler.kind) {
                    .pointer => standard_protocol.wl_seat.capability.pointer,
                    .keyboard => standard_protocol.wl_seat.capability.keyboard,
                    .touch => standard_protocol.wl_seat.capability.touch,
                    else => unreachable,
                };
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_seat,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .capabilities = .{ .capabilities = capability } },
                );
                try wayring.server.sendEvent(
                    standard_protocol,
                    standard_protocol.wl_seat,
                    handler.objects,
                    handler.queue,
                    resource,
                    .{ .name = .{ .name = "wayring-seat" } },
                );
                handler.seat_advertised = true;
            }
        } else if (interface == &standard_protocol.wp_presentation.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wp_presentation,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .feedback => |value| {
                    const feedback = (try standard_protocol.wp_presentation.admit_feedback(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).callback;
                    handler.feedback_count += 1;
                    if (handler.feedback_count == 1) {
                        try wayring.server.sendEvent(
                            standard_protocol,
                            standard_protocol.wp_presentation_feedback,
                            handler.objects,
                            handler.queue,
                            feedback,
                            .{ .presented = .{
                                .tv_sec_hi = 1,
                                .tv_sec_lo = 2,
                                .tv_nsec = 3,
                                .refresh = 16_666_667,
                                .seq_hi = 4,
                                .seq_lo = 5,
                                .flags = .vsync,
                            } },
                        );
                        handler.feedback_presented = true;
                    } else if (handler.feedback_count == 2) {
                        try wayring.server.sendEvent(
                            standard_protocol,
                            standard_protocol.wp_presentation_feedback,
                            handler.objects,
                            handler.queue,
                            feedback,
                            .{ .discarded = .{} },
                        );
                        handler.feedback_discarded = true;
                    } else return error.UnexpectedRequest;
                },
                .destroy => {},
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_data_device_manager.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_data_device_manager,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .create_data_source => |value| {
                    _ = try standard_protocol.wl_data_device_manager.admit_create_data_source(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    );
                    handler.data_source_created = true;
                },
                .get_data_device => |value| {
                    _ = try standard_protocol.wl_data_device_manager.admit_get_data_device(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    );
                    handler.data_device_created = true;
                },
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_data_source.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_data_source,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .offer => |value| {
                    if (!std.mem.eql(u8, value.mime_type, "text/plain"))
                        return error.InvalidMimeType;
                    handler.mime_offered = true;
                },
                .destroy => {
                    if (handler.selection_read_fd < 0) return error.MissingSelection;
                    var received: ["libwayland-selection\x00".len]u8 = undefined;
                    try readExactInterop(handler.selection_read_fd, &received);
                    _ = linux.close(handler.selection_read_fd);
                    handler.selection_read_fd = -1;
                    if (!std.mem.eql(u8, &received, "libwayland-selection\x00"))
                        return error.InvalidSelection;
                    handler.data_source_destroyed = true;
                },
                .set_actions => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_data_device.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_data_device,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .set_selection => |value| {
                    if (!handler.mime_offered or value.serial != 77 or value.source == null)
                        return error.InvalidSelection;
                    const source = handler.objects.namespace.lookupHandle(value.source.?) orelse
                        return error.UnknownObject;
                    var pipe: [2]linux.fd_t = undefined;
                    const pipe_result = linux.pipe2(&pipe, .{ .CLOEXEC = true });
                    if (linux.errno(pipe_result) != .SUCCESS) return error.SystemCallFailed;
                    wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_data_source,
                        handler.objects,
                        handler.queue,
                        source,
                        .{ .send = .{ .mime_type = "text/plain", .fd = pipe[1] } },
                    ) catch |err| {
                        _ = linux.close(pipe[0]);
                        _ = linux.close(pipe[1]);
                        return err;
                    };
                    handler.selection_read_fd = pipe[0];
                    handler.selection_set = true;
                    handler.selection_sent = true;
                },
                .release => handler.data_device_released = true,
                .start_drag => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_seat.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_seat,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .get_pointer => |value| {
                    const surface = handler.surface orelse return error.MissingSurface;
                    const pointer = (try standard_protocol.wl_seat.admit_get_pointer(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).id;
                    handler.pointer_created = true;
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .enter = .{
                            .serial = 41,
                            .surface = surface.id,
                            .surface_x = 896,
                            .surface_y = -576,
                        } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .motion = .{ .time = 100, .surface_x = 1024, .surface_y = 1280 } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .button = .{
                            .serial = 42,
                            .time = 101,
                            .button = 0x110,
                            .state = .pressed,
                        } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .axis_source = .{ .axis_source = .wheel } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .axis = .{
                            .time = 102,
                            .axis = .vertical_scroll,
                            .value = -256,
                        } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .axis_discrete = .{ .axis = .vertical_scroll, .discrete = -1 } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .axis_value120 = .{ .axis = .vertical_scroll, .value120 = -120 } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .axis_stop = .{ .time = 103, .axis = .vertical_scroll } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_pointer,
                        handler.objects,
                        handler.queue,
                        pointer,
                        .{ .frame = .{} },
                    );
                    handler.pointer_sent = true;
                },
                .get_keyboard => |value| {
                    const surface = handler.surface orelse return error.MissingSurface;
                    const keyboard = (try standard_protocol.wl_seat.admit_get_keyboard(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).id;
                    handler.keyboard_created = true;
                    const keymap = "xkb_keymap {}\x00";
                    const descriptor_result = linux.memfd_create(
                        "wayring-keymap",
                        linux.MFD.CLOEXEC,
                    );
                    if (linux.errno(descriptor_result) != .SUCCESS)
                        return error.SystemCallFailed;
                    const descriptor: linux.fd_t = @intCast(descriptor_result);
                    writeExactInterop(descriptor, keymap) catch |err| {
                        _ = linux.close(descriptor);
                        return err;
                    };
                    const seek_result = linux.lseek(descriptor, 0, 0);
                    if (linux.errno(seek_result) != .SUCCESS) {
                        _ = linux.close(descriptor);
                        return error.SystemCallFailed;
                    }
                    wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_keyboard,
                        handler.objects,
                        handler.queue,
                        keyboard,
                        .{ .repeat_info = .{ .rate = 25, .delay = 600 } },
                    ) catch |err| {
                        _ = linux.close(descriptor);
                        return err;
                    };
                    wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_keyboard,
                        handler.objects,
                        handler.queue,
                        keyboard,
                        .{ .keymap = .{
                            .format = .xkb_v1,
                            .fd = descriptor,
                            .size = keymap.len,
                        } },
                    ) catch |err| {
                        _ = linux.close(descriptor);
                        return err;
                    };
                    const keys = [_]u8{ 30, 0, 0, 0, 31, 0, 0, 0 };
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_keyboard,
                        handler.objects,
                        handler.queue,
                        keyboard,
                        .{ .enter = .{ .serial = 41, .surface = surface.id, .keys = &keys } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_keyboard,
                        handler.objects,
                        handler.queue,
                        keyboard,
                        .{ .modifiers = .{
                            .serial = 42,
                            .mods_depressed = 1,
                            .mods_latched = 2,
                            .mods_locked = 4,
                            .group = 3,
                        } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_keyboard,
                        handler.objects,
                        handler.queue,
                        keyboard,
                        .{ .key = .{
                            .serial = 43,
                            .time = 100,
                            .key = 30,
                            .state = .pressed,
                        } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_keyboard,
                        handler.objects,
                        handler.queue,
                        keyboard,
                        .{ .leave = .{ .serial = 44, .surface = surface.id } },
                    );
                    handler.keyboard_sent = true;
                },
                .release => handler.seat_released = true,
                .get_touch => |value| {
                    const surface = handler.surface orelse return error.MissingSurface;
                    const touch = (try standard_protocol.wl_seat.admit_get_touch(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).id;
                    handler.touch_created = true;
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .down = .{
                            .serial = 51,
                            .time = 200,
                            .surface = surface.id,
                            .id = 7,
                            .x = 384,
                            .y = -512,
                        } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .motion = .{ .time = 201, .id = 7, .x = 768, .y = 1024 } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .shape = .{ .id = 7, .major = 1280, .minor = 512 } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .orientation = .{ .id = 7, .orientation = -11520 } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .frame = .{} },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .up = .{ .serial = 52, .time = 202, .id = 7 } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .frame = .{} },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .down = .{
                            .serial = 53,
                            .time = 203,
                            .surface = surface.id,
                            .id = 8,
                            .x = 0,
                            .y = 0,
                        } },
                    );
                    try wayring.server.sendEvent(
                        standard_protocol,
                        standard_protocol.wl_touch,
                        handler.objects,
                        handler.queue,
                        touch,
                        .{ .cancel = .{} },
                    );
                    handler.touch_sent = true;
                },
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_pointer.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_pointer,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .release => handler.pointer_released = true,
                .set_cursor => return error.UnexpectedRequest,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_keyboard.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_keyboard,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .release => handler.keyboard_released = true,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_touch.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_touch,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .release => handler.touch_released = true,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
        } else if (interface == &standard_protocol.wl_output.info) {
            const decoded = try wayring.server.decodeRequest(
                standard_protocol.wl_output,
                handler.objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .release => handler.output_released = true,
            }
            try decoded.finish(standard_protocol, handler.objects, handler.queue);
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
                    handler.params_created_count += 1;
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
                    handler.plane_added_count += 1;
                },
                .create => |value| {
                    if (!handler.plane_added or value.height != 1 or
                        value.format != drm_format_argb8888 or value.flags.value != 0)
                        return error.InvalidDmabufBuffer;
                    if (value.width == 1) {
                        _ = try standard_protocol.zwp_linux_buffer_params_v1.construct_event_created(
                            standard_protocol,
                            handler.objects,
                            handler.queue,
                            decoded.handle,
                            .{},
                        );
                        handler.async_buffer_created = true;
                    } else if (value.width == 2) {
                        try wayring.server.sendEvent(
                            standard_protocol,
                            standard_protocol.zwp_linux_buffer_params_v1,
                            handler.objects,
                            handler.queue,
                            decoded.handle,
                            .{ .failed = .{} },
                        );
                        handler.create_failed = true;
                    } else return error.InvalidDmabufBuffer;
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
                .destroy => {
                    handler.params_destroyed = handler.buffer_destroyed;
                    handler.params_destroyed_count += 1;
                },
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
                    const buffer = (try standard_protocol.wl_shm_pool.admit_create_buffer(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).id;
                    handler.buffer = buffer;
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
                .destroy => {
                    handler.buffer_destroyed = true;
                    handler.buffer_destroyed_count += 1;
                },
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
                .create_surface => |value| {
                    const surface = (try standard_protocol.wl_compositor.admit_create_surface(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).id;
                    if (handler.kind == .shm) handler.surface_created = true;
                    if (handler.kind == .pointer or handler.kind == .keyboard or
                        handler.kind == .touch)
                        handler.surface = surface;
                },
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
                .destroy => {
                    if (handler.kind == .shm) handler.surface_destroyed = true;
                    if (handler.kind == .pointer or handler.kind == .keyboard or
                        handler.kind == .touch)
                        handler.surface_destroyed = true;
                },
                .attach => |value| {
                    if (handler.kind != .shm or value.buffer == null or
                        value.buffer.? != handler.buffer.?.id or value.x != 2 or value.y != -3)
                        return error.InvalidSurface;
                },
                .damage => |value| {
                    if (handler.kind != .shm or value.x != 1 or value.y != 2 or
                        value.width != 3 or value.height != 4)
                        return error.InvalidSurface;
                },
                .frame => |value| {
                    if (handler.kind != .shm) return error.UnexpectedRequest;
                    handler.frame_callback = (try standard_protocol.wl_surface.admit_frame(
                        handler.objects,
                        decoded.handle,
                        value,
                        .{},
                    )).callback;
                },
                .damage_buffer => |value| {
                    if (handler.kind != .shm or value.x != 5 or value.y != 6 or
                        value.width != 7 or value.height != 8)
                        return error.InvalidSurface;
                },
                .commit => {
                    if (handler.kind == .shm) {
                        try wayring.server.sendEvent(
                            standard_protocol,
                            standard_protocol.wl_buffer,
                            handler.objects,
                            handler.queue,
                            handler.buffer orelse return error.MissingBuffer,
                            .{ .release = .{} },
                        );
                        handler.buffer_released = true;
                        try XdgServerCore.completeSync(
                            handler.objects,
                            handler.queue,
                            handler.frame_callback orelse return error.MissingCallback,
                            123,
                        );
                        handler.frame_completed = true;
                        handler.surface_committed = true;
                    }
                },
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
        handler.presentation == null or !handler.synced or !handler.deleted or
        !handler.pinged or !handler.clock_seen)
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
    const first_feedback = (try standard_protocol.wp_presentation.construct_feedback(
        client_objects,
        &actor.transmit,
        handler.presentation.?,
        .{ .surface = surface.id },
    )).callback;
    handler.feedback = first_feedback;
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .commit = .{} },
    );
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.configured or !handler.feedback_presented or handler.feedback_deletes != 1)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const second_feedback = (try standard_protocol.wp_presentation.construct_feedback(
        client_objects,
        &actor.transmit,
        handler.presentation.?,
        .{ .surface = surface.id },
    )).callback;
    if (second_feedback.id != first_feedback.id) return error.FeedbackIdNotReused;
    handler.feedback = second_feedback;
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .commit = .{} },
    );
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.feedback_discarded or handler.feedback_deletes != 2)
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
    try wayring.client.sendRequest(
        standard_protocol.wp_presentation,
        client_objects,
        &actor.transmit,
        handler.presentation.?,
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
    presentation: ?wayring.objects.Handle = null,
    feedback: ?wayring.objects.Handle = null,
    xdg_surface: ?wayring.objects.Handle = null,
    toplevel: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    pinged: bool = false,
    configured: bool = false,
    clock_seen: bool = false,
    feedback_presented: bool = false,
    feedback_discarded: bool = false,
    feedback_deletes: usize = 0,

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
                    if (handler.feedback) |feedback| if (deleted.id == feedback.id) {
                        handler.feedback_deletes += 1;
                        if (handler.feedback_deletes == 2) handler.feedback = null;
                    };
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
                    } else if (std.mem.eql(
                        u8,
                        global.interface,
                        standard_protocol.wp_presentation.info.name,
                    )) {
                        handler.presentation = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wp_presentation.info,
                            1,
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
        } else if (interface == &standard_protocol.wp_presentation.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wp_presentation,
                handler.objects,
                handler.presentation orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .clock_id => |value| {
                    if (value.clk_id != 1) return error.InvalidClock;
                    handler.clock_seen = true;
                },
            }
        } else if (interface == &standard_protocol.wp_presentation_feedback.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wp_presentation_feedback,
                handler.objects,
                handler.feedback orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .presented => |value| {
                    if (value.tv_sec_hi != 1 or value.tv_sec_lo != 2 or
                        value.tv_nsec != 3 or value.refresh != 16_666_667 or
                        value.seq_hi != 4 or value.seq_lo != 5 or
                        value.flags.value != standard_protocol.wp_presentation_feedback.kind.vsync.value)
                        return error.InvalidPresentation;
                    handler.feedback_presented = true;
                },
                .discarded => handler.feedback_discarded = true,
                .sync_output => return error.UnexpectedEvent,
            }
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

fn wayringPointerClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.pointer_server_fd(sockets[1]));
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
    var handler: PointerClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.compositor == null or handler.seat == null or
        !handler.capabilities or !handler.name or !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const surface = (try standard_protocol.wl_compositor.construct_create_surface(
        client_objects,
        &actor.transmit,
        handler.compositor.?,
        .{},
    )).id;
    const pointer = (try standard_protocol.wl_seat.construct_get_pointer(
        client_objects,
        &actor.transmit,
        handler.seat.?,
        .{},
    )).id;
    handler.surface = surface;
    handler.pointer = pointer;
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.enter or !handler.motion or !handler.button or !handler.axis or
        !handler.axis_source or !handler.axis_stop or !handler.axis_discrete or
        !handler.axis_value120 or !handler.frame or !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.wl_pointer,
        client_objects,
        &actor.transmit,
        pointer,
        .{ .release = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_seat,
        client_objects,
        &actor.transmit,
        handler.seat.?,
        .{ .release = .{} },
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

const PointerClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    pointer: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    capabilities: bool = false,
    name: bool = false,
    enter: bool = false,
    motion: bool = false,
    button: bool = false,
    axis: bool = false,
    axis_source: bool = false,
    axis_stop: bool = false,
    axis_discrete: bool = false,
    axis_value120: bool = false,
    frame: bool = false,

    pub fn event(
        handler: *PointerClientHandler,
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
                    } else if (std.mem.eql(u8, global.interface, standard_protocol.wl_seat.info.name)) {
                        handler.seat = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_seat.info,
                            @min(global.version, 8),
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
        } else if (interface == &standard_protocol.wl_seat.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_seat,
                handler.objects,
                handler.seat orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .capabilities => |value| {
                    if (value.capabilities.value != standard_protocol.wl_seat.capability.pointer.value)
                        return error.InvalidCapabilities;
                    handler.capabilities = true;
                },
                .name => |value| {
                    if (!std.mem.eql(u8, value.name, "wayring-seat")) return error.InvalidSeat;
                    handler.name = true;
                },
            }
        } else if (interface == &standard_protocol.wl_pointer.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_pointer,
                handler.objects,
                handler.pointer orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .enter => |value| {
                    if (value.serial != 41 or value.surface != handler.surface.?.id or
                        value.surface_x != 896 or value.surface_y != -576)
                        return error.InvalidPointer;
                    handler.enter = true;
                },
                .motion => |value| {
                    if (value.time != 100 or value.surface_x != 1024 or value.surface_y != 1280)
                        return error.InvalidPointer;
                    handler.motion = true;
                },
                .button => |value| {
                    if (value.serial != 42 or value.time != 101 or value.button != 0x110 or
                        value.state.value != standard_protocol.wl_pointer.button_state.pressed.value)
                        return error.InvalidPointer;
                    handler.button = true;
                },
                .axis => |value| {
                    if (value.time != 102 or value.axis.value !=
                        standard_protocol.wl_pointer.axis.vertical_scroll.value or value.value != -256)
                        return error.InvalidPointer;
                    handler.axis = true;
                },
                .axis_source => |value| {
                    if (value.axis_source.value != standard_protocol.wl_pointer.axis_source.wheel.value)
                        return error.InvalidPointer;
                    handler.axis_source = true;
                },
                .axis_stop => |value| {
                    if (value.time != 103 or value.axis.value !=
                        standard_protocol.wl_pointer.axis.vertical_scroll.value)
                        return error.InvalidPointer;
                    handler.axis_stop = true;
                },
                .axis_discrete => |value| {
                    if (value.axis.value != standard_protocol.wl_pointer.axis.vertical_scroll.value or
                        value.discrete != -1)
                        return error.InvalidPointer;
                    handler.axis_discrete = true;
                },
                .axis_value120 => |value| {
                    if (value.axis.value != standard_protocol.wl_pointer.axis.vertical_scroll.value or
                        value.value120 != -120)
                        return error.InvalidPointer;
                    handler.axis_value120 = true;
                },
                .frame => handler.frame = true,
                .leave => return error.UnexpectedEvent,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn wayringKeyboardClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.keyboard_server_fd(sockets[1]));
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
    var handler: KeyboardClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.compositor == null or handler.seat == null or
        !handler.capabilities or !handler.name or !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const surface = (try standard_protocol.wl_compositor.construct_create_surface(
        client_objects,
        &actor.transmit,
        handler.compositor.?,
        .{},
    )).id;
    const keyboard = (try standard_protocol.wl_seat.construct_get_keyboard(
        client_objects,
        &actor.transmit,
        handler.seat.?,
        .{},
    )).id;
    handler.surface = surface;
    handler.keyboard = keyboard;
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.keymap or !handler.enter or !handler.modifiers or !handler.key or
        !handler.repeat_info or !handler.leave or !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.wl_keyboard,
        client_objects,
        &actor.transmit,
        keyboard,
        .{ .release = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_seat,
        client_objects,
        &actor.transmit,
        handler.seat.?,
        .{ .release = .{} },
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

const KeyboardClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    keyboard: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    capabilities: bool = false,
    name: bool = false,
    keymap: bool = false,
    enter: bool = false,
    modifiers: bool = false,
    key: bool = false,
    repeat_info: bool = false,
    leave: bool = false,

    pub fn event(
        handler: *KeyboardClientHandler,
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
                    } else if (std.mem.eql(u8, global.interface, standard_protocol.wl_seat.info.name)) {
                        handler.seat = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_seat.info,
                            @min(global.version, 8),
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
        } else if (interface == &standard_protocol.wl_seat.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_seat,
                handler.objects,
                handler.seat orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .capabilities => |value| {
                    if (value.capabilities.value != standard_protocol.wl_seat.capability.keyboard.value)
                        return error.InvalidCapabilities;
                    handler.capabilities = true;
                },
                .name => |value| {
                    if (!std.mem.eql(u8, value.name, "wayring-seat")) return error.InvalidSeat;
                    handler.name = true;
                },
            }
        } else if (interface == &standard_protocol.wl_keyboard.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_keyboard,
                handler.objects,
                handler.keyboard orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .keymap => |value| {
                    defer _ = linux.close(value.fd);
                    const expected = "xkb_keymap {}\x00";
                    var keymap: [expected.len]u8 = undefined;
                    const flags = linux.fcntl(value.fd, linux.F.GETFD, 0);
                    if (value.format.value != standard_protocol.wl_keyboard.keymap_format.xkb_v1.value or
                        value.size != expected.len or linux.errno(flags) != .SUCCESS or
                        flags & linux.FD_CLOEXEC == 0)
                        return error.InvalidKeymap;
                    try readExactInterop(value.fd, &keymap);
                    if (!std.mem.eql(u8, &keymap, expected)) return error.InvalidKeymap;
                    handler.keymap = true;
                },
                .enter => |value| {
                    const expected = [_]u8{ 30, 0, 0, 0, 31, 0, 0, 0 };
                    if (!handler.keymap or value.serial != 41 or
                        value.surface != handler.surface.?.id or
                        !std.mem.eql(u8, value.keys, &expected))
                        return error.InvalidKeyboard;
                    handler.enter = true;
                },
                .modifiers => |value| {
                    if (!handler.enter or value.serial != 42 or value.mods_depressed != 1 or
                        value.mods_latched != 2 or value.mods_locked != 4 or value.group != 3)
                        return error.InvalidKeyboard;
                    handler.modifiers = true;
                },
                .key => |value| {
                    if (!handler.repeat_info or !handler.modifiers or value.serial != 43 or
                        value.time != 100 or value.key != 30 or value.state.value !=
                        standard_protocol.wl_keyboard.key_state.pressed.value)
                        return error.InvalidKeyboard;
                    handler.key = true;
                },
                .repeat_info => |value| {
                    if (value.rate != 25 or value.delay != 600) return error.InvalidKeyboard;
                    handler.repeat_info = true;
                },
                .leave => |value| {
                    if (!handler.key or value.serial != 44 or value.surface != handler.surface.?.id)
                        return error.InvalidKeyboard;
                    handler.leave = true;
                },
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn wayringTouchClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.touch_server_fd(sockets[1]));
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
    var handler: TouchClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.compositor == null or handler.seat == null or
        !handler.capabilities or !handler.name or !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const surface = (try standard_protocol.wl_compositor.construct_create_surface(
        client_objects,
        &actor.transmit,
        handler.compositor.?,
        .{},
    )).id;
    const touch = (try standard_protocol.wl_seat.construct_get_touch(
        client_objects,
        &actor.transmit,
        handler.seat.?,
        .{},
    )).id;
    handler.surface = surface;
    handler.touch = touch;
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.down != 2 or !handler.motion or !handler.shape or !handler.orientation or
        !handler.up or handler.frames != 2 or !handler.cancel or
        !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.wl_touch,
        client_objects,
        &actor.transmit,
        touch,
        .{ .release = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_seat,
        client_objects,
        &actor.transmit,
        handler.seat.?,
        .{ .release = .{} },
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

const TouchClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    touch: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    capabilities: bool = false,
    name: bool = false,
    down: usize = 0,
    motion: bool = false,
    shape: bool = false,
    orientation: bool = false,
    up: bool = false,
    frames: usize = 0,
    cancel: bool = false,

    pub fn event(
        handler: *TouchClientHandler,
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
                    } else if (std.mem.eql(u8, global.interface, standard_protocol.wl_seat.info.name)) {
                        handler.seat = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_seat.info,
                            @min(global.version, 8),
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
        } else if (interface == &standard_protocol.wl_seat.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_seat,
                handler.objects,
                handler.seat orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .capabilities => |value| {
                    if (value.capabilities.value != standard_protocol.wl_seat.capability.touch.value)
                        return error.InvalidCapabilities;
                    handler.capabilities = true;
                },
                .name => |value| {
                    if (!std.mem.eql(u8, value.name, "wayring-seat")) return error.InvalidSeat;
                    handler.name = true;
                },
            }
        } else if (interface == &standard_protocol.wl_touch.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_touch,
                handler.objects,
                handler.touch orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .down => |value| {
                    const valid = if (handler.down == 0)
                        value.serial == 51 and value.time == 200 and value.id == 7 and
                            value.x == 384 and value.y == -512
                    else
                        handler.down == 1 and value.serial == 53 and value.time == 203 and
                            value.id == 8 and value.x == 0 and value.y == 0;
                    if (!valid or value.surface != handler.surface.?.id)
                        return error.InvalidTouch;
                    handler.down += 1;
                },
                .motion => |value| {
                    if (value.time != 201 or value.id != 7 or value.x != 768 or value.y != 1024)
                        return error.InvalidTouch;
                    handler.motion = true;
                },
                .shape => |value| {
                    if (value.id != 7 or value.major != 1280 or value.minor != 512)
                        return error.InvalidTouch;
                    handler.shape = true;
                },
                .orientation => |value| {
                    if (value.id != 7 or value.orientation != -11520)
                        return error.InvalidTouch;
                    handler.orientation = true;
                },
                .up => |value| {
                    if (value.serial != 52 or value.time != 202 or value.id != 7)
                        return error.InvalidTouch;
                    handler.up = true;
                },
                .frame => handler.frames += 1,
                .cancel => {
                    if (handler.down != 2) return error.InvalidTouch;
                    handler.cancel = true;
                },
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn wayringOutputClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.output_server_fd(sockets[1]));
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
        .{ .max_objects = 12, .max_client_ids = 11 },
    );
    const peer = connection.peer;
    const actor = try connection.actor();
    const client_objects = &connection.objects;
    const registry = try XdgClientCore.getRegistry(client_objects, &actor.transmit, null);
    const callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    var handler: OutputClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.output == null or !handler.geometry or !handler.mode or
        !handler.scale or !handler.name or !handler.description or !handler.done or
        !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.wl_output,
        client_objects,
        &actor.transmit,
        handler.output.?,
        .{ .release = .{} },
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

const OutputClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    output: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    geometry: bool = false,
    mode: bool = false,
    scale: bool = false,
    name: bool = false,
    description: bool = false,
    done: bool = false,

    pub fn event(
        handler: *OutputClientHandler,
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
                    standard_protocol.wl_output.info.name,
                )) {
                    handler.output = try XdgClientCore.bind(
                        handler.objects,
                        handler.queue,
                        handler.registry,
                        global.name,
                        &standard_protocol.wl_output.info,
                        @min(global.version, 4),
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
        } else if (interface == &standard_protocol.wl_output.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_output,
                handler.objects,
                handler.output orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .geometry => |value| {
                    if (value.x != -10 or value.y != 20 or value.physical_width != 600 or
                        value.physical_height != 340 or value.subpixel.value !=
                        standard_protocol.wl_output.subpixel.horizontal_rgb.value or
                        !std.mem.eql(u8, value.make, "Wayring") or
                        !std.mem.eql(u8, value.model, "Virtual-1") or
                        value.transform.value != standard_protocol.wl_output.transform.@"90".value)
                        return error.InvalidOutput;
                    handler.geometry = true;
                },
                .mode => |value| {
                    if (value.flags.value != 3 or value.width != 1920 or value.height != 1080 or
                        value.refresh != 60_000)
                        return error.InvalidOutput;
                    handler.mode = true;
                },
                .scale => |value| {
                    if (value.factor != 2) return error.InvalidOutput;
                    handler.scale = true;
                },
                .name => |value| {
                    if (!std.mem.eql(u8, value.name, "WL-1")) return error.InvalidOutput;
                    handler.name = true;
                },
                .description => |value| {
                    if (!std.mem.eql(u8, value.description, "Wayring virtual output"))
                        return error.InvalidOutput;
                    handler.description = true;
                },
                .done => handler.done = true,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn wayringDataDeviceClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.data_device_server_fd(sockets[1]));
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
        .{ .max_objects = 20, .max_client_ids = 19 },
    );
    const peer = connection.peer;
    const actor = try connection.actor();
    const client_objects = &connection.objects;
    const registry = try XdgClientCore.getRegistry(client_objects, &actor.transmit, null);
    const callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    var handler: DataDeviceClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.seat == null or handler.manager == null or
        !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const source = (try standard_protocol.wl_data_device_manager.construct_create_data_source(
        client_objects,
        &actor.transmit,
        handler.manager.?,
        .{},
    )).id;
    const device = (try standard_protocol.wl_data_device_manager.construct_get_data_device(
        client_objects,
        &actor.transmit,
        handler.manager.?,
        .{ .seat = handler.seat.?.id },
    )).id;
    handler.source = source;
    handler.device = device;
    try wayring.client.sendRequest(
        standard_protocol.wl_data_source,
        client_objects,
        &actor.transmit,
        source,
        .{ .offer = .{ .mime_type = "text/plain" } },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_data_device,
        client_objects,
        &actor.transmit,
        device,
        .{ .set_selection = .{ .source = source.id, .serial = 77 } },
    );
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.source_sent or handler.offer == null or !handler.offer_mime or
        !handler.selection_received or !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    var offer_pipe: [2]linux.fd_t = undefined;
    const pipe_result = linux.pipe2(&offer_pipe, .{ .CLOEXEC = true });
    if (linux.errno(pipe_result) != .SUCCESS) return error.SystemCallFailed;
    wayring.client.sendRequest(
        standard_protocol.wl_data_offer,
        client_objects,
        &actor.transmit,
        handler.offer.?,
        .{ .receive = .{ .mime_type = "text/plain", .fd = offer_pipe[1] } },
    ) catch |err| {
        _ = linux.close(offer_pipe[0]);
        _ = linux.close(offer_pipe[1]);
        return err;
    };
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);
    var offer_bytes: ["libwayland-offer\x00".len]u8 = undefined;
    readExactInterop(offer_pipe[0], &offer_bytes) catch |err| {
        _ = linux.close(offer_pipe[0]);
        return err;
    };
    _ = linux.close(offer_pipe[0]);
    if (!std.mem.eql(u8, &offer_bytes, "libwayland-offer\x00"))
        return error.InvalidSelection;

    try wayring.client.sendRequest(
        standard_protocol.wl_data_offer,
        client_objects,
        &actor.transmit,
        handler.offer.?,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_data_source,
        client_objects,
        &actor.transmit,
        source,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_data_device,
        client_objects,
        &actor.transmit,
        device,
        .{ .release = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_seat,
        client_objects,
        &actor.transmit,
        handler.seat.?,
        .{ .release = .{} },
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

const DataDeviceClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    seat: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    source: ?wayring.objects.Handle = null,
    device: ?wayring.objects.Handle = null,
    offer: ?wayring.objects.Handle = null,
    synced: bool = false,
    deleted: bool = false,
    source_sent: bool = false,
    offer_mime: bool = false,
    selection_received: bool = false,

    pub fn event(
        handler: *DataDeviceClientHandler,
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
                    if (std.mem.eql(u8, global.interface, standard_protocol.wl_seat.info.name)) {
                        handler.seat = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_seat.info,
                            @min(global.version, 7),
                            null,
                        );
                    } else if (std.mem.eql(
                        u8,
                        global.interface,
                        standard_protocol.wl_data_device_manager.info.name,
                    )) {
                        handler.manager = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_data_device_manager.info,
                            @min(global.version, 3),
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
        } else if (interface == &standard_protocol.wl_data_source.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_data_source,
                handler.objects,
                handler.source orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .send => |value| {
                    defer _ = linux.close(value.fd);
                    const flags = linux.fcntl(value.fd, linux.F.GETFD, 0);
                    if (linux.errno(flags) != .SUCCESS or flags & linux.FD_CLOEXEC == 0 or
                        !std.mem.eql(u8, value.mime_type, "text/plain"))
                        return error.InvalidSelection;
                    try writeExactInterop(value.fd, "wayring-selection\x00");
                    handler.source_sent = true;
                },
                else => return error.UnexpectedEvent,
            }
        } else if (interface == &standard_protocol.wl_data_device.info) {
            const device = handler.device orelse return error.UnexpectedEvent;
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_data_device,
                handler.objects,
                device,
                message,
                fds,
            );
            switch (event_value) {
                .data_offer => |value| {
                    handler.offer = (try standard_protocol.wl_data_device.admit_event_data_offer(
                        handler.objects,
                        device,
                        value,
                        .{},
                    )).id;
                },
                .selection => |value| {
                    if (value.id == null or handler.offer == null or
                        value.id.? != handler.offer.?.id)
                        return error.InvalidSelection;
                    handler.selection_received = true;
                },
                else => return error.UnexpectedEvent,
            }
        } else if (interface == &standard_protocol.wl_data_offer.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_data_offer,
                handler.objects,
                handler.offer orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .offer => |value| {
                    if (!std.mem.eql(u8, value.mime_type, "text/plain"))
                        return error.InvalidMimeType;
                    handler.offer_mime = true;
                },
                else => return error.UnexpectedEvent,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

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
    while (handler.shm == null or handler.compositor == null or !handler.format_seen or
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
    const surface = (try standard_protocol.wl_compositor.construct_create_surface(
        client_objects,
        &actor.transmit,
        handler.compositor.?,
        .{},
    )).id;
    handler.buffer = buffer;
    handler.surface = surface;
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .attach = .{ .buffer = buffer.id, .x = 2, .y = -3 } },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .damage = .{ .x = 1, .y = 2, .width = 3, .height = 4 } },
    );
    handler.frame = (try standard_protocol.wl_surface.construct_frame(
        client_objects,
        &actor.transmit,
        surface,
        .{},
    )).callback;
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .damage_buffer = .{ .x = 5, .y = 6, .width = 7, .height = 8 } },
    );
    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .commit = .{} },
    );
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.buffer_released or !handler.frame_done or
        !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.wl_surface,
        client_objects,
        &actor.transmit,
        surface,
        .{ .destroy = .{} },
    );
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
    compositor: ?wayring.objects.Handle = null,
    buffer: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    frame: ?wayring.objects.Handle = null,
    format_seen: bool = false,
    buffer_released: bool = false,
    frame_done: bool = false,
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
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, standard_protocol.wl_shm.info.name)) {
                        handler.shm = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_shm.info,
                            @min(global.version, 1),
                            null,
                        );
                    } else if (std.mem.eql(
                        u8,
                        global.interface,
                        standard_protocol.wl_compositor.info.name,
                    )) {
                        handler.compositor = try XdgClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &standard_protocol.wl_compositor.info,
                            @min(global.version, 4),
                            null,
                        );
                    }
                },
                .global_remove => {},
            }
        } else if (interface == &XdgClientCore.Callback.info) {
            if (handler.frame) |frame| {
                if (message.header.object_id == frame.id) {
                    const event_value = try XdgClientCore.decodeCallbackEvent(
                        handler.objects,
                        frame,
                        message,
                        fds,
                    );
                    if (event_value.done.callback_data != 123) return error.InvalidFrame;
                    handler.frame_done = true;
                    handler.frame = null;
                } else {
                    _ = try XdgClientCore.decodeCallbackEvent(
                        handler.objects,
                        handler.callback,
                        message,
                        fds,
                    );
                    handler.synced = true;
                }
            } else {
                _ = try XdgClientCore.decodeCallbackEvent(
                    handler.objects,
                    handler.callback,
                    message,
                    fds,
                );
                handler.synced = true;
            }
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
        } else if (interface == &standard_protocol.wl_buffer.info) {
            const event_value = try wayring.client.decodeEvent(
                standard_protocol.wl_buffer,
                handler.objects,
                handler.buffer orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (event_value) {
                .release => handler.buffer_released = true,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

fn wayringDmabufClient() !u8 {
    var sockets: [2]c_int = undefined;
    if (c.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets) != 0)
        return error.SystemCallFailed;
    const child = c.fork();
    if (child < 0) return error.SystemCallFailed;
    if (child == 0) {
        _ = c.close(sockets[0]);
        c._exit(ffi.dmabuf_server_fd(sockets[1]));
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
    var handler: DmabufClientHandler = .{
        .objects = client_objects,
        .queue = &actor.transmit,
        .registry = registry,
        .callback = callback,
    };
    try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.dmabuf == null or !handler.modifier_seen or
        !handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const descriptor_result = linux.memfd_create("wayring-dmabuf-interop", linux.MFD.CLOEXEC);
    if (linux.errno(descriptor_result) != .SUCCESS) return error.SystemCallFailed;
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    if (linux.errno(linux.ftruncate(descriptor, 4096)) != .SUCCESS) {
        _ = linux.close(descriptor);
        return error.SystemCallFailed;
    }
    const params = (try standard_protocol.zwp_linux_dmabuf_v1.construct_create_params(
        client_objects,
        &actor.transmit,
        handler.dmabuf.?,
        .{},
    )).params_id;
    wayring.client.sendRequest(
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        params,
        .{ .add = .{
            .fd = descriptor,
            .plane_idx = 0,
            .offset = 0,
            .stride = 4,
            .modifier_hi = drm_format_modifier_invalid_hi,
            .modifier_lo = drm_format_modifier_invalid_lo,
        } },
    ) catch |err| {
        _ = linux.close(descriptor);
        return err;
    };
    const buffer = (try standard_protocol.zwp_linux_buffer_params_v1.construct_create_immed(
        client_objects,
        &actor.transmit,
        params,
        .{
            .width = 1,
            .height = 1,
            .format = drm_format_argb8888,
            .flags = .fromInt(0),
        },
    )).buffer_id;
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
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        params,
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

    const async_descriptor_result = linux.memfd_create(
        "wayring-dmabuf-async",
        linux.MFD.CLOEXEC,
    );
    if (linux.errno(async_descriptor_result) != .SUCCESS) return error.SystemCallFailed;
    const async_descriptor: linux.fd_t = @intCast(async_descriptor_result);
    if (linux.errno(linux.ftruncate(async_descriptor, 4096)) != .SUCCESS) {
        _ = linux.close(async_descriptor);
        return error.SystemCallFailed;
    }
    const async_params = (try standard_protocol.zwp_linux_dmabuf_v1.construct_create_params(
        client_objects,
        &actor.transmit,
        handler.dmabuf.?,
        .{},
    )).params_id;
    wayring.client.sendRequest(
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        async_params,
        .{ .add = .{
            .fd = async_descriptor,
            .plane_idx = 0,
            .offset = 0,
            .stride = 4,
            .modifier_hi = drm_format_modifier_invalid_hi,
            .modifier_lo = drm_format_modifier_invalid_lo,
        } },
    ) catch |err| {
        _ = linux.close(async_descriptor);
        return err;
    };
    handler.active_params = async_params;
    try wayring.client.sendRequest(
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        async_params,
        .{ .create = .{
            .width = 1,
            .height = 1,
            .format = drm_format_argb8888,
            .flags = .fromInt(0),
        } },
    );
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (handler.async_buffer == null)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.wl_buffer,
        client_objects,
        &actor.transmit,
        handler.async_buffer.?,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        async_params,
        .{ .destroy = .{} },
    );
    handler.synced = false;
    handler.deleted = false;
    handler.callback = try XdgClientCore.sync(client_objects, &actor.transmit, null);
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.synced or !handler.deleted)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    const failed_descriptor_result = linux.memfd_create(
        "wayring-dmabuf-failure",
        linux.MFD.CLOEXEC,
    );
    if (linux.errno(failed_descriptor_result) != .SUCCESS) return error.SystemCallFailed;
    const failed_descriptor: linux.fd_t = @intCast(failed_descriptor_result);
    if (linux.errno(linux.ftruncate(failed_descriptor, 4096)) != .SUCCESS) {
        _ = linux.close(failed_descriptor);
        return error.SystemCallFailed;
    }
    const failed_params = (try standard_protocol.zwp_linux_dmabuf_v1.construct_create_params(
        client_objects,
        &actor.transmit,
        handler.dmabuf.?,
        .{},
    )).params_id;
    wayring.client.sendRequest(
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        failed_params,
        .{ .add = .{
            .fd = failed_descriptor,
            .plane_idx = 0,
            .offset = 0,
            .stride = 4,
            .modifier_hi = drm_format_modifier_invalid_hi,
            .modifier_lo = drm_format_modifier_invalid_lo,
        } },
    ) catch |err| {
        _ = linux.close(failed_descriptor);
        return err;
    };
    handler.active_params = failed_params;
    try wayring.client.sendRequest(
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        failed_params,
        .{ .create = .{
            .width = 2,
            .height = 1,
            .format = drm_format_argb8888,
            .flags = .fromInt(0),
        } },
    );
    if (!actor.transmit.sendActive()) try reactor.prepareSend(peer);
    _ = try reactor.ring.submit();
    while (!handler.create_failed)
        try pumpProtocolClient(&reactor, peer, client_objects, &handler);

    try wayring.client.sendRequest(
        standard_protocol.zwp_linux_buffer_params_v1,
        client_objects,
        &actor.transmit,
        failed_params,
        .{ .destroy = .{} },
    );
    try wayring.client.sendRequest(
        standard_protocol.zwp_linux_dmabuf_v1,
        client_objects,
        &actor.transmit,
        handler.dmabuf.?,
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

const DmabufClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    callback: wayring.objects.Handle,
    dmabuf: ?wayring.objects.Handle = null,
    active_params: ?wayring.objects.Handle = null,
    async_buffer: ?wayring.objects.Handle = null,
    modifier_seen: bool = false,
    create_failed: bool = false,
    synced: bool = false,
    deleted: bool = false,

    pub fn event(
        handler: *DmabufClientHandler,
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
                    standard_protocol.zwp_linux_dmabuf_v1.info.name,
                )) {
                    handler.dmabuf = try XdgClientCore.bind(
                        handler.objects,
                        handler.queue,
                        handler.registry,
                        global.name,
                        &standard_protocol.zwp_linux_dmabuf_v1.info,
                        @min(global.version, 3),
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
        } else if (interface == &standard_protocol.zwp_linux_dmabuf_v1.info) {
            const dmabuf_event = try wayring.client.decodeEvent(
                standard_protocol.zwp_linux_dmabuf_v1,
                handler.objects,
                handler.dmabuf orelse return error.UnexpectedEvent,
                message,
                fds,
            );
            switch (dmabuf_event) {
                .modifier => |value| {
                    if (value.format == drm_format_argb8888 and
                        value.modifier_hi == drm_format_modifier_invalid_hi and
                        value.modifier_lo == drm_format_modifier_invalid_lo)
                        handler.modifier_seen = true;
                },
                .format => {},
            }
        } else if (interface == &standard_protocol.zwp_linux_buffer_params_v1.info) {
            const params = handler.active_params orelse return error.UnexpectedEvent;
            const params_event = try wayring.client.decodeEvent(
                standard_protocol.zwp_linux_buffer_params_v1,
                handler.objects,
                params,
                message,
                fds,
            );
            switch (params_event) {
                .created => |value| {
                    handler.async_buffer = (try standard_protocol.zwp_linux_buffer_params_v1.admit_event_created(
                        handler.objects,
                        params,
                        value,
                        .{},
                    )).buffer;
                },
                .failed => handler.create_failed = true,
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

fn readExactInterop(fd: linux.fd_t, bytes: []u8) !void {
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

fn writeExactInterop(fd: linux.fd_t, bytes: []const u8) !void {
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
        } else if (std.mem.eql(u8, value, "dmabuf-libwayland-server")) {
            options.mode = .dmabuf_libwayland_server;
        } else if (std.mem.eql(u8, value, "data-device-libwayland-client")) {
            options.mode = .data_device_libwayland_client;
        } else if (std.mem.eql(u8, value, "data-device-libwayland-server")) {
            options.mode = .data_device_libwayland_server;
        } else if (std.mem.eql(u8, value, "output-libwayland-client")) {
            options.mode = .output_libwayland_client;
        } else if (std.mem.eql(u8, value, "output-libwayland-server")) {
            options.mode = .output_libwayland_server;
        } else if (std.mem.eql(u8, value, "pointer-libwayland-client")) {
            options.mode = .pointer_libwayland_client;
        } else if (std.mem.eql(u8, value, "pointer-libwayland-server")) {
            options.mode = .pointer_libwayland_server;
        } else if (std.mem.eql(u8, value, "keyboard-libwayland-client")) {
            options.mode = .keyboard_libwayland_client;
        } else if (std.mem.eql(u8, value, "keyboard-libwayland-server")) {
            options.mode = .keyboard_libwayland_server;
        } else if (std.mem.eql(u8, value, "touch-libwayland-client")) {
            options.mode = .touch_libwayland_client;
        } else if (std.mem.eql(u8, value, "touch-libwayland-server")) {
            options.mode = .touch_libwayland_server;
        } else return error.InvalidMode;
    }
    if (iterator.next() != null or options.messages == 0 or options.batch == 0 or
        options.warmup == 0 or options.warmup > std.math.maxInt(u64) - options.messages or
        (options.latency and options.warmup + options.messages > std.math.maxInt(u32)))
        return error.InvalidArguments;
    return options;
}
