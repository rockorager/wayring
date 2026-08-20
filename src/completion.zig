//! Identity carried in io_uring's 64-bit `user_data` field.

const std = @import("std");

pub const Operation = enum(u8) {
    receive = 1,
    send = 2,
    cancel = 3,
    accept = 4,
    accept_cancel = 5,
};

pub const Token = struct {
    operation: Operation,
    slot: u24,
    generation: u32,

    pub fn encode(token: Token) u64 {
        return @intFromEnum(token.operation) |
            (@as(u64, token.slot) << 8) |
            (@as(u64, token.generation) << 32);
    }

    pub fn decode(value: u64) error{UnknownOperation}!Token {
        const operation = std.enums.fromInt(Operation, @as(u8, @truncate(value))) orelse
            return error.UnknownOperation;
        return .{
            .operation = operation,
            .slot = @truncate(value >> 8),
            .generation = @truncate(value >> 32),
        };
    }

    pub fn belongsTo(token: Token, slot: u24, generation: u32) bool {
        return token.slot == slot and token.generation == generation;
    }
};

/// Zero is reserved for never-initialized slots.
pub fn nextGeneration(current: u32) u32 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

test "completion token round trips" {
    const expected: Token = .{
        .operation = .receive,
        .slot = 0xabcdef,
        .generation = 0x12345678,
    };
    try std.testing.expectEqual(expected, try Token.decode(expected.encode()));
}

test "generation rejects stale completions and skips zero" {
    const token: Token = .{ .operation = .send, .slot = 7, .generation = 10 };
    try std.testing.expect(token.belongsTo(7, 10));
    try std.testing.expect(!token.belongsTo(7, 11));
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(std.math.maxInt(u32)));
}

test "rejects unknown operations" {
    try std.testing.expectError(error.UnknownOperation, Token.decode(0));
}
