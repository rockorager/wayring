//! A Wayland implementation designed around Linux io_uring.
//!
//! Wayring is experimental and makes no API stability guarantees.

const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux) @compileError("wayring supports Linux only");
}

pub const wire = @import("wire.zig");
pub const ancillary = @import("ancillary.zig");
pub const completion = @import("completion.zig");
pub const stream = @import("stream.zig");
pub const reactor = @import("reactor.zig");
pub const tx = @import("tx.zig");
pub const connection = @import("connection.zig");
pub const pool = @import("pool.zig");
pub const protocol = @import("protocol.zig");
pub const codegen = @import("codegen.zig");
pub const objects = @import("objects.zig");
pub const metadata = @import("metadata.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");
pub const dispatch = @import("dispatch.zig");
pub const io_uring = @import("io_uring.zig");
pub const unix_socket = @import("unix_socket.zig");
pub const compositor = @import("compositor.zig");
pub const region = @import("region.zig");
pub const frame = @import("frame.zig");
pub const subsurface = @import("subsurface.zig");
pub const release = @import("release.zig");

test {
    _ = wire;
    _ = ancillary;
    _ = completion;
    _ = stream;
    _ = reactor;
    _ = tx;
    _ = connection;
    _ = pool;
    _ = protocol;
    _ = codegen;
    _ = objects;
    _ = metadata;
    _ = client;
    _ = server;
    _ = dispatch;
    _ = io_uring;
    _ = unix_socket;
    _ = compositor;
    _ = region;
    _ = frame;
    _ = subsurface;
    _ = release;
}
