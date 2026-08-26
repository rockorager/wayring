//! Generation-aware routing for io_uring completions.

const std = @import("std");
const completion = @import("completion.zig");

pub const Error = error{
    SlotOutOfRange,
    SlotInactive,
    WrongGeneration,
    SlotSpaceExhausted,
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

/// Connection records remain separately allocated at stable addresses. This
/// growable directory contains only completion-routing metadata, so relocating
/// it during cold-path admission cannot invalidate an in-flight kernel pointer.
/// Inactive slots form an intrusive free list and are recycled in O(1).
pub const Slots = struct {
    storage: std.ArrayListUnmanaged(Slot) = .empty,
    free_head: u32 = free_end,
    active_count: usize = 0,

    pub fn deinit(slots: *Slots, allocator: std.mem.Allocator) void {
        std.debug.assert(slots.active_count == 0);
        slots.storage.deinit(allocator);
        slots.* = undefined;
    }

    pub const Acquired = struct {
        index: u24,
        generation: u32,
    };

    pub fn acquire(slots: *Slots, allocator: std.mem.Allocator) !Acquired {
        const index = if (slots.free_head == free_end) index: {
            if (slots.storage.items.len > std.math.maxInt(u24))
                return error.SlotSpaceExhausted;
            const appended: u24 = @intCast(slots.storage.items.len);
            try slots.storage.append(allocator, .{});
            break :index appended;
        } else index: {
            const recycled = slots.free_head;
            slots.free_head = slots.storage.items[recycled].next_free;
            break :index @as(u24, @intCast(recycled));
        };
        const slot = &slots.storage.items[index];
        slot.generation = completion.nextGeneration(slot.generation);
        slot.next_free = active_sentinel;
        slots.active_count += 1;
        return .{ .index = index, .generation = slot.generation };
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
        if (index >= slots.storage.items.len) return null;
        return &slots.storage.items[index];
    }
};

test "routes current generations and discards stale completions" {
    var slots: Slots = .{};
    defer slots.deinit(std.testing.allocator);
    const first = try slots.acquire(std.testing.allocator);
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
    const second = try slots.acquire(std.testing.allocator);
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
    try slots.deactivate(second.index, second.generation);
}

test "rejects invalid slot transitions" {
    var slots: Slots = .{};
    defer slots.deinit(std.testing.allocator);
    const acquired = try slots.acquire(std.testing.allocator);
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
    var slots: Slots = .{};
    defer slots.deinit(std.testing.allocator);
    const first = try slots.acquire(std.testing.allocator);
    const second = try slots.acquire(std.testing.allocator);
    try std.testing.expectEqual(@as(u24, 0), first.index);
    try std.testing.expectEqual(@as(u24, 1), second.index);
    try std.testing.expectEqual(@as(usize, 2), slots.active_count);

    try slots.deactivate(first.index, first.generation);
    const recycled = try slots.acquire(std.testing.allocator);
    const third = try slots.acquire(std.testing.allocator);
    try std.testing.expectEqual(first.index, recycled.index);
    try std.testing.expectEqual(@as(u24, 2), third.index);
    try std.testing.expectEqual(@as(usize, 3), slots.storage.items.len);
    try slots.deactivate(recycled.index, recycled.generation);
    try slots.deactivate(second.index, second.generation);
    try slots.deactivate(third.index, third.generation);
}
