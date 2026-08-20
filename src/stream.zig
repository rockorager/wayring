//! Incremental framing for a Unix byte stream.

const std = @import("std");
const wire = @import("wire.zig");
const pools = @import("pool.zig");

pub const Error = wire.DecodeError || pools.Error || error{MessageTooLarge};
const inline_scratch_size = 64;

/// Returns complete messages directly from receive buffers whenever possible.
/// Only a message fragment spanning receive buffers is copied into `scratch`.
/// A returned message is borrowed until the next call to `next`.
pub const Framer = struct {
    scratch: []u8,
    buffered: usize = 0,
    shared_blocks: ?*pools.SharedBlocks = null,
    lease: ?pools.Lease = null,
    release_before_next: bool = false,
    inline_scratch: [inline_scratch_size]u8 = undefined,

    pub fn init(scratch: []u8) Framer {
        return .{ .scratch = scratch };
    }

    /// Leases scratch space only when a message spans receive buffers.
    pub fn initShared(shared_blocks: *pools.SharedBlocks) Framer {
        return .{ .scratch = &.{}, .shared_blocks = shared_blocks };
    }

    pub fn deinit(framer: *Framer) void {
        framer.releaseLease();
        framer.* = undefined;
    }

    pub fn pending(framer: Framer) usize {
        return framer.buffered;
    }

    pub fn next(framer: *Framer, input: *[]const u8) Error!?wire.Message {
        if (framer.release_before_next) {
            framer.releaseLease();
            framer.release_before_next = false;
        }

        if (framer.buffered == 0) {
            if (try wire.Message.decode(input.*)) |message| {
                input.* = input.*[message.header.size..];
                return message;
            }
            if (input.len == 0) return null;
            try framer.ensureCapacity(input.len);
            if (input.len > framer.scratch.len) return error.MessageTooLarge;
            @memcpy(framer.scratch[0..input.len], input.*);
            framer.buffered = input.len;
            input.* = input.*[input.len..];
        }

        if (framer.buffered < wire.header_len) {
            const count = @min(wire.header_len - framer.buffered, input.len);
            if (framer.buffered + count > framer.scratch.len)
                return error.MessageTooLarge;
            @memcpy(framer.scratch[framer.buffered..][0..count], input.*[0..count]);
            framer.buffered += count;
            input.* = input.*[count..];
            if (framer.buffered < wire.header_len) return null;
        }

        const header = (try wire.Header.decode(framer.scratch[0..framer.buffered])).?;
        try framer.ensureCapacity(header.size);
        const count = @min(@as(usize, header.size) - framer.buffered, input.len);
        @memcpy(framer.scratch[framer.buffered..][0..count], input.*[0..count]);
        framer.buffered += count;
        input.* = input.*[count..];
        if (framer.buffered < header.size) return null;

        const message = (try wire.Message.decode(framer.scratch[0..framer.buffered])).?;
        framer.buffered = 0;
        framer.release_before_next = framer.lease != null;
        return message;
    }

    fn ensureCapacity(framer: *Framer, required: usize) Error!void {
        if (framer.scratch.len >= required) return;
        const shared_blocks = framer.shared_blocks orelse return error.MessageTooLarge;
        if (required <= framer.inline_scratch.len and framer.lease == null) {
            framer.scratch = &framer.inline_scratch;
            return;
        }
        if (framer.lease != null) return error.MessageTooLarge;

        const lease = try shared_blocks.acquire();
        if (lease.bytes.len < required) {
            try shared_blocks.release(lease);
            return error.MessageTooLarge;
        }
        @memcpy(lease.bytes[0..framer.buffered], framer.scratch[0..framer.buffered]);
        framer.lease = lease;
        framer.scratch = lease.bytes;
    }

    fn releaseLease(framer: *Framer) void {
        const lease = framer.lease orelse return;
        framer.shared_blocks.?.release(lease) catch unreachable;
        framer.lease = null;
        framer.scratch = &framer.inline_scratch;
    }
};

fn testMessage(storage: *[12]u8, value: u32) ![]const u8 {
    try (wire.Header{ .object_id = 7, .opcode = 3, .size = 12 }).encode(storage[0..8]);
    std.mem.writeInt(u32, storage[8..12], value, @import("builtin").cpu.arch.endian());
    return storage;
}

test "returns complete messages without copying" {
    var bytes: [12]u8 = undefined;
    const encoded = try testMessage(&bytes, 42);
    var scratch: [64]u8 = undefined;
    var framer = Framer.init(&scratch);
    var input = encoded;

    const message = (try framer.next(&input)).?;
    try std.testing.expectEqual(@intFromPtr(encoded.ptr), @intFromPtr(message.payload.ptr) - wire.header_len);
    try std.testing.expectEqual(@as(usize, 0), input.len);
    var arguments = message.arguments();
    try std.testing.expectEqual(@as(u32, 42), try arguments.uint());
}

test "assembles every split of a fragmented message" {
    var bytes: [12]u8 = undefined;
    const encoded = try testMessage(&bytes, 42);

    for (0..encoded.len) |split| {
        var scratch: [64]u8 = undefined;
        var framer = Framer.init(&scratch);
        var first = encoded[0..split];
        try std.testing.expectEqual(null, try framer.next(&first));
        var second = encoded[split..];
        const message = (try framer.next(&second)).?;
        var arguments = message.arguments();
        try std.testing.expectEqual(@as(u32, 42), try arguments.uint());
        try arguments.finish();
    }
}

test "leaves following messages in the input" {
    var first_storage: [12]u8 = undefined;
    var second_storage: [12]u8 = undefined;
    _ = try testMessage(&first_storage, 1);
    _ = try testMessage(&second_storage, 2);
    const bytes = first_storage ++ second_storage;
    var scratch: [64]u8 = undefined;
    var framer = Framer.init(&scratch);
    var input: []const u8 = &bytes;

    try std.testing.expect((try framer.next(&input)) != null);
    try std.testing.expectEqual(@as(usize, 12), input.len);
    try std.testing.expect((try framer.next(&input)) != null);
    try std.testing.expectEqual(@as(usize, 0), input.len);
}

test "fragmented messages lease shared scratch only while borrowed" {
    const allocator = std.testing.allocator;
    var blocks = try pools.SharedBlocks.init(allocator, 128, 1);
    defer blocks.deinit(allocator);
    var first = Framer.initShared(&blocks);
    defer first.deinit();
    var second = Framer.initShared(&blocks);
    defer second.deinit();

    var bytes: [80]u8 = undefined;
    try (wire.Header{ .object_id = 7, .opcode = 3, .size = 80 }).encode(bytes[0..8]);
    @memset(bytes[8..], 0);
    const encoded: []const u8 = &bytes;
    var first_prefix: []const u8 = encoded[0..8];
    try std.testing.expectEqual(null, try first.next(&first_prefix));
    try std.testing.expectEqual(@as(usize, 0), blocks.available());

    var second_prefix: []const u8 = encoded[0..8];
    try std.testing.expectError(error.Exhausted, second.next(&second_prefix));

    var suffix: []const u8 = encoded[8..];
    const message = (try first.next(&suffix)).?;
    try std.testing.expectEqual(@as(u16, 80), message.header.size);
    try std.testing.expectEqual(@as(usize, 0), blocks.available());

    var empty: []const u8 = &.{};
    try std.testing.expectEqual(null, try first.next(&empty));
    try std.testing.expectEqual(@as(usize, 1), blocks.available());
    second_prefix = encoded[0..8];
    try std.testing.expectEqual(null, try second.next(&second_prefix));
}
