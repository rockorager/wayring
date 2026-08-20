//! Wayland wire framing and argument decoding.

const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

pub const header_len = 8;
pub const max_message_len = std.math.maxInt(u16);

pub const DecodeError = error{
    NullSender,
    InvalidSize,
    UnalignedSize,
    UnexpectedEnd,
    LengthOverflow,
    InvalidString,
    TrailingArguments,
};

pub const EncodeError = error{
    NullSender,
    InvalidSize,
    UnalignedSize,
};

pub const Header = struct {
    object_id: u32,
    opcode: u16,
    size: u16,

    /// Returns null until all eight header bytes are available.
    pub fn decode(bytes: []const u8) DecodeError!?Header {
        if (bytes.len < header_len) return null;

        const object_id = readU32(bytes[0..4]);
        const word = readU32(bytes[4..8]);
        const size: u16 = @truncate(word >> 16);

        if (object_id == 0) return error.NullSender;
        if (size < header_len) return error.InvalidSize;
        if (size % 4 != 0) return error.UnalignedSize;

        return .{
            .object_id = object_id,
            .opcode = @truncate(word),
            .size = size,
        };
    }

    pub fn encode(header: Header, bytes: *[header_len]u8) EncodeError!void {
        if (header.object_id == 0) return error.NullSender;
        if (header.size < header_len) return error.InvalidSize;
        if (header.size % 4 != 0) return error.UnalignedSize;

        writeU32(bytes[0..4], header.object_id);
        writeU32(
            bytes[4..8],
            (@as(u32, header.size) << 16) | @as(u32, header.opcode),
        );
    }
};

/// A complete message borrowed directly from a receive buffer.
pub const Message = struct {
    header: Header,
    payload: []const u8,

    /// Decodes the first complete message without copying it.
    pub fn decode(bytes: []const u8) DecodeError!?Message {
        const header = try Header.decode(bytes) orelse return null;
        if (bytes.len < header.size) return null;

        return .{
            .header = header,
            .payload = bytes[header_len..header.size],
        };
    }

    pub fn arguments(message: Message) Arguments {
        return .{ .remaining_bytes = message.payload };
    }
};

/// Cursor used by generated decoders to read typed arguments.
pub const Arguments = struct {
    remaining_bytes: []const u8,

    pub fn remaining(arguments: Arguments) usize {
        return arguments.remaining_bytes.len;
    }

    pub fn uint(arguments: *Arguments) DecodeError!u32 {
        const bytes = try arguments.take(4);
        return readU32(bytes[0..4]);
    }

    pub fn int(arguments: *Arguments) DecodeError!i32 {
        return @bitCast(try arguments.uint());
    }

    /// Returns null for a nullable wire string and excludes its trailing NUL.
    pub fn string(arguments: *Arguments) DecodeError!?[]const u8 {
        const len = std.math.cast(usize, try arguments.uint()) orelse
            return error.LengthOverflow;
        if (len == 0) return null;

        const padded = std.math.add(usize, len, 3) catch return error.LengthOverflow;
        const bytes = try arguments.take(padded & ~@as(usize, 3));
        const value = bytes[0..len];
        const string_bytes = value[0 .. len - 1];
        if (value[len - 1] != 0 or std.mem.indexOfScalar(u8, string_bytes, 0) != null) {
            return error.InvalidString;
        }
        return string_bytes;
    }

    pub fn array(arguments: *Arguments) DecodeError![]const u8 {
        const len = std.math.cast(usize, try arguments.uint()) orelse
            return error.LengthOverflow;
        const padded = std.math.add(usize, len, 3) catch return error.LengthOverflow;
        const bytes = try arguments.take(padded & ~@as(usize, 3));
        return bytes[0..len];
    }

    pub fn finish(arguments: Arguments) DecodeError!void {
        if (arguments.remaining_bytes.len != 0) return error.TrailingArguments;
    }

    fn take(arguments: *Arguments, len: usize) DecodeError![]const u8 {
        if (arguments.remaining_bytes.len < len) return error.UnexpectedEnd;
        const value = arguments.remaining_bytes[0..len];
        arguments.remaining_bytes = arguments.remaining_bytes[len..];
        return value;
    }
};

inline fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, native_endian);
}

fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, native_endian);
}

fn frame(storage: []u8, object_id: u32, opcode: u16, payload: []const u8) []const u8 {
    const size = header_len + payload.len;
    std.debug.assert(size <= max_message_len and size % 4 == 0);
    std.debug.assert(storage.len >= size);

    writeU32(storage[0..4], object_id);
    writeU32(storage[4..8], (@as(u32, @intCast(size)) << 16) | opcode);
    @memcpy(storage[header_len..size], payload);
    return storage[0..size];
}

test "waits for fragmented header and payload" {
    var storage: [12]u8 = undefined;
    const bytes = frame(&storage, 7, 3, &std.mem.toBytes(@as(u32, 42)));

    for (0..bytes.len) |split| {
        try std.testing.expectEqual(null, try Message.decode(bytes[0..split]));
    }

    const message = (try Message.decode(bytes)).?;
    try std.testing.expectEqual(@as(u32, 7), message.header.object_id);
    try std.testing.expectEqual(@as(u16, 3), message.header.opcode);
    var arguments = message.arguments();
    try std.testing.expectEqual(@as(u32, 42), try arguments.uint());
}

test "leaves a following message unconsumed" {
    var storage: [16]u8 = undefined;
    _ = frame(storage[0..8], 1, 0, &.{});
    _ = frame(storage[8..16], 2, 1, &.{});

    const message = (try Message.decode(&storage)).?;
    try std.testing.expectEqual(@as(u32, 1), message.header.object_id);
    try std.testing.expectEqual(@as(usize, 0), message.payload.len);
}

test "rejects invalid headers" {
    var storage: [8]u8 = undefined;
    _ = frame(&storage, 0, 0, &.{});
    try std.testing.expectError(error.NullSender, Header.decode(&storage));

    _ = frame(&storage, 1, 0, &.{});
    writeU32(storage[4..8], @as(u32, 4) << 16);
    try std.testing.expectError(error.InvalidSize, Header.decode(&storage));

    writeU32(storage[4..8], @as(u32, 10) << 16);
    try std.testing.expectError(error.UnalignedSize, Header.decode(&storage));
}

test "encodes a header in native byte order" {
    var bytes: [header_len]u8 = undefined;
    const expected: Header = .{ .object_id = 7, .opcode = 3, .size = 12 };
    try expected.encode(&bytes);
    try std.testing.expectEqual(expected, (try Header.decode(&bytes)).?);
}

test "decodes padded string and array without copying" {
    const payload = std.mem.toBytes(@as(u32, 3)) ++ "ok\x00\x00" ++
        std.mem.toBytes(@as(u32, 2)) ++ [_]u8{ 9, 8, 0, 0 };
    var storage: [24]u8 = undefined;
    const bytes = frame(&storage, 1, 0, payload);
    var arguments = (try Message.decode(bytes)).?.arguments();

    try std.testing.expectEqualStrings("ok", (try arguments.string()).?);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8 }, try arguments.array());
    try arguments.finish();
}

test "rejects noncanonical strings" {
    const values = [_][4]u8{ "bad!".*, "a\x00b\x00".* };
    for (values) |value| {
        const payload = std.mem.toBytes(@as(u32, 4)) ++ value;
        var storage: [16]u8 = undefined;
        var arguments = (try Message.decode(frame(&storage, 1, 0, &payload))).?.arguments();
        try std.testing.expectError(error.InvalidString, arguments.string());
    }
}
