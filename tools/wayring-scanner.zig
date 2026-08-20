const std = @import("std");
const wayring = @import("wayring");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const xml = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(64 * 1024 * 1024),
    );
    var protocol = try wayring.protocol.Protocol.parse(allocator, xml);
    defer protocol.deinit(allocator);
    const generated = try wayring.codegen.generate(allocator, protocol);

    const output = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
    defer output.close(init.io);
    try output.writeStreamingAll(init.io, generated);
}
