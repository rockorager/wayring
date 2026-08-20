const std = @import("std");
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
