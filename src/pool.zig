//! Reactor-wide storage shared by all connections.

const std = @import("std");
const linux = std.os.linux;

const free_sentinel = std.math.maxInt(u32);

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    CapacityOverflow,
    Exhausted,
    StaleLease,
};

pub const Lease = struct {
    index: u32,
    generation: u32,
    bytes: []u8,
};

pub const FdLease = struct {
    index: u32,
    generation: u32,
    fd: linux.fd_t,
};

/// Fixed-size byte blocks allocated once for a reactor and leased by any of its
/// connections. Acquire and release are O(1) and perform no allocator calls.
pub const SharedBlocks = struct {
    block_size: usize,
    storage: []u8,
    free_next: []u32,
    chain_next: []u32,
    generations: []u32,
    in_use: []bool,
    free_head: u32,
    active_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        block_size: usize,
        block_count: usize,
    ) Error!SharedBlocks {
        if (block_size == 0 or block_count == 0 or block_count > free_sentinel)
            return error.InvalidConfig;
        const byte_count = std.math.mul(usize, block_size, block_count) catch
            return error.CapacityOverflow;

        const storage = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(storage);
        const free_next = try allocator.alloc(u32, block_count);
        errdefer allocator.free(free_next);
        const chain_next = try allocator.alloc(u32, block_count);
        errdefer allocator.free(chain_next);
        const generations = try allocator.alloc(u32, block_count);
        errdefer allocator.free(generations);
        const in_use = try allocator.alloc(bool, block_count);
        errdefer allocator.free(in_use);

        @memset(generations, 0);
        @memset(in_use, false);
        @memset(chain_next, free_sentinel);
        for (free_next, 0..) |*next, index| {
            next.* = if (index + 1 < block_count)
                @intCast(index + 1)
            else
                free_sentinel;
        }

        return .{
            .block_size = block_size,
            .storage = storage,
            .free_next = free_next,
            .chain_next = chain_next,
            .generations = generations,
            .in_use = in_use,
            .free_head = 0,
        };
    }

    pub fn deinit(blocks: *SharedBlocks, allocator: std.mem.Allocator) void {
        std.debug.assert(blocks.active_count == 0);
        allocator.free(blocks.in_use);
        allocator.free(blocks.generations);
        allocator.free(blocks.chain_next);
        allocator.free(blocks.free_next);
        allocator.free(blocks.storage);
        blocks.* = undefined;
    }

    pub fn acquire(blocks: *SharedBlocks) Error!Lease {
        if (blocks.free_head == free_sentinel) return error.Exhausted;
        const index = blocks.free_head;
        blocks.free_head = blocks.free_next[index];
        blocks.generations[index] = nextGeneration(blocks.generations[index]);
        blocks.in_use[index] = true;
        blocks.chain_next[index] = free_sentinel;
        blocks.active_count += 1;
        return .{
            .index = index,
            .generation = blocks.generations[index],
            .bytes = blocks.bytes(index),
        };
    }

    pub fn release(blocks: *SharedBlocks, lease: Lease) Error!void {
        try blocks.validate(lease);

        blocks.in_use[lease.index] = false;
        blocks.chain_next[lease.index] = free_sentinel;
        blocks.free_next[lease.index] = blocks.free_head;
        blocks.free_head = lease.index;
        blocks.active_count -= 1;
    }

    pub fn capacity(blocks: SharedBlocks) usize {
        return blocks.free_next.len;
    }

    pub fn available(blocks: SharedBlocks) usize {
        return blocks.capacity() - blocks.active_count;
    }

    pub fn allocatedBytes(blocks: SharedBlocks) usize {
        return blocks.storage.len +
            blocks.free_next.len * @sizeOf(u32) +
            blocks.chain_next.len * @sizeOf(u32) +
            blocks.generations.len * @sizeOf(u32) +
            blocks.in_use.len * @sizeOf(bool);
    }

    pub fn link(blocks: *SharedBlocks, from: Lease, to: Lease) Error!void {
        try blocks.validate(from);
        try blocks.validate(to);
        if (blocks.chain_next[from.index] != free_sentinel) return error.InvalidConfig;
        blocks.chain_next[from.index] = to.index;
    }

    pub fn nextLease(blocks: *SharedBlocks, lease: Lease) Error!?Lease {
        try blocks.validate(lease);
        const index = blocks.chain_next[lease.index];
        if (index == free_sentinel) return null;
        if (!blocks.in_use[index]) return error.StaleLease;
        return .{
            .index = index,
            .generation = blocks.generations[index],
            .bytes = blocks.bytes(index),
        };
    }

    fn validate(blocks: SharedBlocks, lease: Lease) Error!void {
        if (lease.index >= blocks.free_next.len or
            !blocks.in_use[lease.index] or
            blocks.generations[lease.index] != lease.generation)
            return error.StaleLease;
        const expected = blocks.bytes(lease.index);
        if (lease.bytes.ptr != expected.ptr or lease.bytes.len != expected.len)
            return error.StaleLease;
    }

    fn bytes(blocks: SharedBlocks, index: u32) []u8 {
        const start = @as(usize, index) * blocks.block_size;
        return blocks.storage[start..][0..blocks.block_size];
    }
};

/// Descriptor entries shared by all receive and transmit queues on a reactor.
/// The pool owns a descriptor from `acquire` until `take` returns it.
pub const SharedFds = struct {
    fds: []linux.fd_t,
    free_next: []u32,
    chain_next: []u32,
    generations: []u32,
    in_use: []bool,
    free_head: u32,
    active_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity_value: usize) Error!SharedFds {
        if (capacity_value == 0 or capacity_value > free_sentinel)
            return error.InvalidConfig;
        const fds = try allocator.alloc(linux.fd_t, capacity_value);
        errdefer allocator.free(fds);
        const free_next = try allocator.alloc(u32, capacity_value);
        errdefer allocator.free(free_next);
        const chain_next = try allocator.alloc(u32, capacity_value);
        errdefer allocator.free(chain_next);
        const generations = try allocator.alloc(u32, capacity_value);
        errdefer allocator.free(generations);
        const in_use = try allocator.alloc(bool, capacity_value);
        errdefer allocator.free(in_use);

        @memset(chain_next, free_sentinel);
        @memset(generations, 0);
        @memset(in_use, false);
        for (free_next, 0..) |*next, index| {
            next.* = if (index + 1 < capacity_value)
                @intCast(index + 1)
            else
                free_sentinel;
        }
        return .{
            .fds = fds,
            .free_next = free_next,
            .chain_next = chain_next,
            .generations = generations,
            .in_use = in_use,
            .free_head = 0,
        };
    }

    pub fn deinit(fds: *SharedFds, allocator: std.mem.Allocator) void {
        std.debug.assert(fds.active_count == 0);
        allocator.free(fds.in_use);
        allocator.free(fds.generations);
        allocator.free(fds.chain_next);
        allocator.free(fds.free_next);
        allocator.free(fds.fds);
        fds.* = undefined;
    }

    pub fn acquire(fds: *SharedFds, fd: linux.fd_t) Error!FdLease {
        if (fds.free_head == free_sentinel) return error.Exhausted;
        const index = fds.free_head;
        fds.free_head = fds.free_next[index];
        fds.generations[index] = nextGeneration(fds.generations[index]);
        fds.fds[index] = fd;
        fds.chain_next[index] = free_sentinel;
        fds.in_use[index] = true;
        fds.active_count += 1;
        return .{ .index = index, .generation = fds.generations[index], .fd = fd };
    }

    /// Releases an entry and transfers descriptor ownership to the caller.
    pub fn take(fds: *SharedFds, lease: FdLease) Error!linux.fd_t {
        try fds.validate(lease);
        fds.in_use[lease.index] = false;
        fds.chain_next[lease.index] = free_sentinel;
        fds.free_next[lease.index] = fds.free_head;
        fds.free_head = lease.index;
        fds.active_count -= 1;
        return lease.fd;
    }

    pub fn link(fds: *SharedFds, from: FdLease, to: FdLease) Error!void {
        try fds.validate(from);
        try fds.validate(to);
        if (fds.chain_next[from.index] != free_sentinel) return error.InvalidConfig;
        fds.chain_next[from.index] = to.index;
    }

    pub fn nextLease(fds: *SharedFds, lease: FdLease) Error!?FdLease {
        try fds.validate(lease);
        const index = fds.chain_next[lease.index];
        if (index == free_sentinel) return null;
        if (!fds.in_use[index]) return error.StaleLease;
        return .{
            .index = index,
            .generation = fds.generations[index],
            .fd = fds.fds[index],
        };
    }

    pub fn capacity(fds: SharedFds) usize {
        return fds.fds.len;
    }

    pub fn available(fds: SharedFds) usize {
        return fds.capacity() - fds.active_count;
    }

    fn validate(fds: SharedFds, lease: FdLease) Error!void {
        if (lease.index >= fds.fds.len or
            !fds.in_use[lease.index] or
            fds.generations[lease.index] != lease.generation or
            fds.fds[lease.index] != lease.fd)
            return error.StaleLease;
    }
};

fn nextGeneration(current: u32) u32 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

test "blocks are shared and recycled without allocation" {
    const allocator = std.testing.allocator;
    var blocks = try SharedBlocks.init(allocator, 4096, 2);
    defer blocks.deinit(allocator);

    const first = try blocks.acquire();
    const second = try blocks.acquire();
    try std.testing.expect(first.bytes.ptr != second.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 0), blocks.available());
    try std.testing.expectError(error.Exhausted, blocks.acquire());

    try blocks.release(first);
    const reused = try blocks.acquire();
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(reused.generation != first.generation);
    try std.testing.expectError(error.StaleLease, blocks.release(first));

    try blocks.release(reused);
    try blocks.release(second);
    try std.testing.expectEqual(@as(usize, 2), blocks.available());
}

test "rejects overflowing pool size" {
    try std.testing.expectError(error.CapacityOverflow, SharedBlocks.init(
        std.testing.allocator,
        std.math.maxInt(usize),
        2,
    ));
}

test "descriptor entries are shared, ordered, and generation safe" {
    const allocator = std.testing.allocator;
    var fds = try SharedFds.init(allocator, 2);
    defer fds.deinit(allocator);

    const first = try fds.acquire(10);
    const second = try fds.acquire(11);
    try fds.link(first, second);
    try std.testing.expectEqual(@as(linux.fd_t, 11), (try fds.nextLease(first)).?.fd);
    try std.testing.expectError(error.Exhausted, fds.acquire(12));
    try std.testing.expectEqual(@as(linux.fd_t, 10), try fds.take(first));
    const reused = try fds.acquire(12);
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expectError(error.StaleLease, fds.take(first));
    try std.testing.expectEqual(@as(linux.fd_t, 12), try fds.take(reused));
    try std.testing.expectEqual(@as(linux.fd_t, 11), try fds.take(second));
}
