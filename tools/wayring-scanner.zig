const std = @import("std");
const wayring = @import("wayring");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) return error.InvalidArguments;

    var protocols: std.ArrayList(wayring.protocol.Protocol) = .empty;
    defer {
        for (protocols.items) |*protocol| protocol.deinit(allocator);
        protocols.deinit(allocator);
    }
    for (args[1 .. args.len - 1]) |path| {
        const xml = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            allocator,
            .limited(64 * 1024 * 1024),
        );
        try protocols.append(
            allocator,
            try wayring.protocol.Protocol.parse(allocator, xml),
        );
    }
    const generated = try wayring.codegen.generateProtocols(allocator, protocols.items);

    const output = try std.Io.Dir.cwd().createFile(init.io, args[args.len - 1], .{});
    defer output.close(init.io);
    try output.writeStreamingAll(init.io, generated);
}
