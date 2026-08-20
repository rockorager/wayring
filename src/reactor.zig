//! Generation-aware routing for io_uring completions.

const std = @import("std");
const completion = @import("completion.zig");

pub const Error = error{
    Exhausted,
    SlotOutOfRange,
    SlotInactive,
    WrongGeneration,
};

const active_sentinel = std.math.maxInt(u32);
const free_end = active_sentinel - 1;

pub const Slot = struct {
    generation: u32 = 0,
    next_free: u32 = free_end,
};

pub const Routed = struct {
    slot: u24,
    operation: completion.Operation,
};

/// Slot storage is caller-owned so a reactor can size it once and perform no
/// allocation while dispatching completions. Inactive slots form an intrusive
/// free list; acquiring and recycling a connection slot are O(1).
pub const Slots = struct {
    storage: []Slot,
    free_head: u32,
    active_count: usize = 0,

    pub fn init(storage: []Slot) Slots {
        std.debug.assert(storage.len <= @as(usize, std.math.maxInt(u24)) + 1);
        for (storage, 0..) |*slot, index| {
            slot.* = .{
                .next_free = if (index + 1 < storage.len)
                    @intCast(index + 1)
                else
                    free_end,
            };
        }
        return .{
            .storage = storage,
            .free_head = if (storage.len == 0) free_end else 0,
        };
    }

    pub const Acquired = struct {
        index: u24,
        generation: u32,
    };

    pub fn acquire(slots: *Slots) Error!Acquired {
        if (slots.free_head == free_end) return error.Exhausted;
        const index = slots.free_head;
        const slot = &slots.storage[index];
        slots.free_head = slot.next_free;
        slot.generation = completion.nextGeneration(slot.generation);
        slot.next_free = active_sentinel;
        slots.active_count += 1;
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    pub fn deactivate(slots: *Slots, index: u24, generation: u32) Error!void {
        const slot = slots.get(index) orelse return error.SlotOutOfRange;
        if (slot.next_free != active_sentinel) return error.SlotInactive;
        if (slot.generation != generation) return error.WrongGeneration;
        slot.next_free = slots.free_head;
        slots.free_head = index;
        slots.active_count -= 1;
    }

    pub fn token(
        slots: Slots,
        index: u24,
        generation: u32,
        operation: completion.Operation,
    ) Error!u64 {
        const slot = slots.get(index) orelse return error.SlotOutOfRange;
        if (slot.next_free != active_sentinel) return error.SlotInactive;
        if (slot.generation != generation) return error.WrongGeneration;
        return (completion.Token{
            .slot = index,
            .generation = generation,
            .operation = operation,
        }).encode();
    }

    /// Returns null for malformed, inactive, or stale completions. Such CQEs
    /// are consumed but must never dereference connection storage.
    pub inline fn route(slots: Slots, user_data: u64) ?Routed {
        const token_value = completion.Token.decode(user_data) catch return null;
        return slots.routeToken(token_value);
    }

    pub inline fn routeToken(slots: Slots, token_value: completion.Token) ?Routed {
        const slot = slots.get(token_value.slot) orelse return null;
        if (slot.next_free != active_sentinel or slot.generation != token_value.generation)
            return null;
        return .{
            .slot = token_value.slot,
            .operation = token_value.operation,
        };
    }

    fn get(slots: Slots, index: u24) ?*Slot {
        if (index >= slots.storage.len) return null;
        return &slots.storage[index];
    }
};

test "routes current generations and discards stale completions" {
    var storage: [2]Slot = undefined;
    var slots = Slots.init(&storage);
    const first = try slots.acquire();
    const stale = try slots.token(first.index, first.generation, .receive);
    try std.testing.expectEqual(
        Routed{
            .slot = first.index,
            .operation = .receive,
        },
        slots.route(stale).?,
    );

    try slots.deactivate(first.index, first.generation);
    try std.testing.expectEqual(null, slots.route(stale));
    const second = try slots.acquire();
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expectEqual(null, slots.route(stale));

    const current = try slots.token(second.index, second.generation, .send);
    try std.testing.expectEqual(
        Routed{
            .slot = second.index,
            .operation = .send,
        },
        slots.route(current).?,
    );
}

test "rejects invalid slot transitions" {
    var storage: [1]Slot = undefined;
    var slots = Slots.init(&storage);
    const acquired = try slots.acquire();
    try std.testing.expectError(error.Exhausted, slots.acquire());
    try std.testing.expectError(
        error.WrongGeneration,
        slots.deactivate(acquired.index, acquired.generation + 1),
    );
    try slots.deactivate(acquired.index, acquired.generation);
    try std.testing.expectError(
        error.SlotInactive,
        slots.deactivate(acquired.index, acquired.generation),
    );
    try std.testing.expectError(error.SlotOutOfRange, slots.token(1, 1, .receive));
}

test "slots stay compact and acquire in deterministic order" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Slot));
    var storage: [3]Slot = undefined;
    var slots = Slots.init(&storage);
    const first = try slots.acquire();
    const second = try slots.acquire();
    try std.testing.expectEqual(@as(u24, 0), first.index);
    try std.testing.expectEqual(@as(u24, 1), second.index);
    try std.testing.expectEqual(@as(usize, 2), slots.active_count);

    try slots.deactivate(first.index, first.generation);
    const recycled = try slots.acquire();
    const third = try slots.acquire();
    try std.testing.expectEqual(first.index, recycled.index);
    try std.testing.expectEqual(@as(u24, 2), third.index);
    try std.testing.expectError(error.Exhausted, slots.acquire());
}
