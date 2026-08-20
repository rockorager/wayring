const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("standard_protocols");

test "production Wayland protocols compose into direct codecs" {
    try std.testing.expectEqualStrings("wl_surface", protocol.wl_surface.info.name);
    try std.testing.expectEqualStrings("xdg_wm_base", protocol.xdg_wm_base.info.name);
    try std.testing.expectEqualStrings("wp_presentation", protocol.wp_presentation.info.name);
    try std.testing.expectEqualStrings("zwp_linux_dmabuf_v1", protocol.zwp_linux_dmabuf_v1.info.name);

    try std.testing.expectEqual(@as(usize, 16), try protocol.xdg_wm_base.requestSize(.{
        .get_xdg_surface = .{ .id = 7, .surface = 5 },
    }));
    try std.testing.expectEqual(@as(usize, 20), try protocol.xdg_toplevel.requestSize(.{
        .resize = .{
            .seat = 9,
            .serial = 11,
            .edges = protocol.xdg_toplevel.resize_edge.bottom_right,
        },
    }));
    try std.testing.expectEqual(@as(usize, 24), try protocol.xdg_toplevel.eventSize(.{
        .configure = .{
            .width = 1920,
            .height = 1080,
            .states = &.{ 1, 0, 0, 0 },
        },
    }));
}

test "xdg-shell constructors validate core objects and transact IDs" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer queue.deinit();
    var objects = try wayring.objects.ClientObjects.init(
        std.testing.allocator,
        8,
        8,
        &protocol.wl_display.info,
        null,
    );
    defer objects.deinit(std.testing.allocator);
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);

    const wm_base = try objects.createLocal(
        &protocol.xdg_wm_base.info,
        protocol.xdg_wm_base.info.version,
        null,
    );
    const surface = try objects.createLocal(
        &protocol.wl_surface.info,
        protocol.wl_surface.info.version,
        null,
    );
    const region = try objects.createLocal(&protocol.wl_region.info, 1, null);
    try std.testing.expectError(
        error.WrongInterface,
        protocol.xdg_wm_base.construct_get_xdg_surface(
            &objects,
            &queue,
            wm_base,
            .{ .surface = region.id },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
    try std.testing.expect(objects.namespace.get(5) == null);

    const xdg_surface = (try protocol.xdg_wm_base.construct_get_xdg_surface(
        &objects,
        &queue,
        wm_base,
        .{ .surface = surface.id },
    )).id;
    try std.testing.expectEqual(@as(u32, 5), xdg_surface.id);
    const surface_request = try protocol.xdg_wm_base.decodeRequestObjects(
        &objects.namespace,
        try firstMessage(&queue),
        &received_fds,
    );
    try std.testing.expectEqual(surface.id, switch (surface_request) {
        .get_xdg_surface => |value| value.surface,
        else => unreachable,
    });
    try consume(&queue);

    const toplevel = (try protocol.xdg_surface.construct_get_toplevel(
        &objects,
        &queue,
        xdg_surface,
        .{},
    )).id;
    try std.testing.expectEqual(@as(u32, 6), toplevel.id);
    try std.testing.expectEqual(
        @min(
            objects.namespace.resolve(xdg_surface).?.version,
            protocol.xdg_toplevel.info.version,
        ),
        objects.namespace.resolve(toplevel).?.version,
    );
    const toplevel_request = try protocol.xdg_surface.decodeRequest(
        try firstMessage(&queue),
        &received_fds,
    );
    try std.testing.expectEqual(toplevel.id, switch (toplevel_request) {
        .get_toplevel => |value| value.id,
        else => unreachable,
    });
}

fn firstMessage(queue: *wayring.tx.Queue) !wayring.wire.Message {
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    return (try wayring.wire.Message.decode(snapshot.first)) orelse error.IncompleteMessage;
}

fn consume(queue: *wayring.tx.Queue) !void {
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    try queue.begin(snapshot);
    try queue.complete(snapshot.byteCount());
}
