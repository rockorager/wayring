const std = @import("std");
const wayring = @import("wayring");
const core_protocol = @import("core_protocol");
const benchmark_protocol = @import("benchmark_protocol");

const ffi = @cImport({
    @cInclude("benchmark.h");
    @cInclude("stdio.h");
});
const c = std.c;
const linux = std.os.linux;
const ClientCore = wayring.client.Core(core_protocol);
const ClientConnection = wayring.client.Connection(core_protocol);
const ServerCore = wayring.server.Core(core_protocol);
const ServerRuntime = wayring.server.Runtime(core_protocol);
const Benchmark = benchmark_protocol.wp_wayring_benchmark_v1;

const Options = struct {
    messages: u64 = 1_000_000,
    batch: u32 = 256,
    warmup: u64 = 100_000,
    mode: enum { libwayland_client, libwayland_server } = .libwayland_client,
    latency: bool = false,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    const options = try parseOptions(init.args);
    return switch (options.mode) {
        .libwayland_client => wayringServer(options),
        .libwayland_server => wayringClient(options),
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
            _ = try wayring.dispatch.receivedEvents(
                actor,
                &client_objects.namespace,
                try reactor.getReceiver(peer),
                completion,
                handler,
            );
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
        } else return error.InvalidMode;
    }
    if (iterator.next() != null or options.messages == 0 or options.batch == 0 or
        options.warmup == 0 or options.warmup > std.math.maxInt(u64) - options.messages or
        (options.latency and options.warmup + options.messages > std.math.maxInt(u32)))
        return error.InvalidArguments;
    return options;
}
