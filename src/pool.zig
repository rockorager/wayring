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

/// Fixed-size byte blocks shared by every connection on a reactor. The initial
/// count is a reserve rather than a ceiling; pointer-stable nodes grow on
/// demand, while acquire and release remain O(1) whenever a free node exists.
pub const SharedBlocks = struct {
    const Node = struct {
        bytes: []u8,
        free_next: u32 = free_sentinel,
        chain_next: u32 = free_sentinel,
        generation: u32 = 0,
        in_use: bool = false,
    };

    allocator: std.mem.Allocator,
    block_size: usize,
    nodes: std.ArrayList(*Node),
    free_head: u32,
    active_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        block_size: usize,
        block_count: usize,
    ) Error!SharedBlocks {
        if (block_size == 0 or block_count == 0 or block_count > free_sentinel)
            return error.InvalidConfig;
        _ = std.math.mul(usize, block_size, block_count) catch
            return error.CapacityOverflow;
        var blocks: SharedBlocks = .{
            .allocator = allocator,
            .block_size = block_size,
            .nodes = .empty,
            .free_head = free_sentinel,
        };
        errdefer blocks.deinitNodes();
        try blocks.ensureAvailable(block_count);
        return blocks;
    }

    pub fn deinit(blocks: *SharedBlocks, allocator: std.mem.Allocator) void {
        std.debug.assert(blocks.active_count == 0);
        std.debug.assert(allocator.ptr == blocks.allocator.ptr);
        blocks.deinitNodes();
        blocks.* = undefined;
    }

    pub fn acquire(blocks: *SharedBlocks) Error!Lease {
        try blocks.ensureAvailable(1);
        const index = blocks.free_head;
        const node = blocks.nodes.items[index];
        blocks.free_head = node.free_next;
        node.generation = nextGeneration(node.generation);
        node.in_use = true;
        node.chain_next = free_sentinel;
        blocks.active_count += 1;
        return .{
            .index = index,
            .generation = node.generation,
            .bytes = node.bytes,
        };
    }

    pub fn release(blocks: *SharedBlocks, lease: Lease) Error!void {
        try blocks.validate(lease);
        const node = blocks.nodes.items[lease.index];
        node.in_use = false;
        node.chain_next = free_sentinel;
        node.free_next = blocks.free_head;
        blocks.free_head = lease.index;
        blocks.active_count -= 1;
    }

    pub fn capacity(blocks: SharedBlocks) usize {
        return blocks.nodes.items.len;
    }

    pub fn available(blocks: SharedBlocks) usize {
        return blocks.capacity() - blocks.active_count;
    }

    pub fn allocatedBytes(blocks: SharedBlocks) usize {
        return blocks.nodes.items.len * (blocks.block_size + @sizeOf(Node) + @sizeOf(*Node));
    }

    pub fn ensureAvailable(blocks: *SharedBlocks, count: usize) Error!void {
        if (count > free_sentinel - blocks.active_count) return error.CapacityOverflow;
        while (blocks.available() < count) try blocks.grow();
    }

    pub fn link(blocks: *SharedBlocks, from: Lease, to: Lease) Error!void {
        try blocks.validate(from);
        try blocks.validate(to);
        const node = blocks.nodes.items[from.index];
        if (node.chain_next != free_sentinel) return error.InvalidConfig;
        node.chain_next = to.index;
    }

    pub fn nextLease(blocks: *SharedBlocks, lease: Lease) Error!?Lease {
        try blocks.validate(lease);
        const index = blocks.nodes.items[lease.index].chain_next;
        if (index == free_sentinel) return null;
        const node = blocks.nodes.items[index];
        if (!node.in_use) return error.StaleLease;
        return .{
            .index = index,
            .generation = node.generation,
            .bytes = node.bytes,
        };
    }

    fn validate(blocks: SharedBlocks, lease: Lease) Error!void {
        if (lease.index >= blocks.nodes.items.len) return error.StaleLease;
        const node = blocks.nodes.items[lease.index];
        if (!node.in_use or node.generation != lease.generation or
            lease.bytes.ptr != node.bytes.ptr or lease.bytes.len != node.bytes.len)
            return error.StaleLease;
    }

    fn grow(blocks: *SharedBlocks) Error!void {
        if (blocks.nodes.items.len >= free_sentinel) return error.CapacityOverflow;
        const node = try blocks.allocator.create(Node);
        errdefer blocks.allocator.destroy(node);
        const bytes = try blocks.allocator.alloc(u8, blocks.block_size);
        errdefer blocks.allocator.free(bytes);
        const index: u32 = @intCast(blocks.nodes.items.len);
        node.* = .{ .bytes = bytes, .free_next = blocks.free_head };
        try blocks.nodes.append(blocks.allocator, node);
        blocks.free_head = index;
    }

    fn deinitNodes(blocks: *SharedBlocks) void {
        for (blocks.nodes.items) |node| {
            blocks.allocator.free(node.bytes);
            blocks.allocator.destroy(node);
        }
        blocks.nodes.deinit(blocks.allocator);
    }
};

/// Descriptor entries shared by all receive and transmit queues on a reactor.
/// The pool owns a descriptor from `acquire` until `take` returns it.
pub const SharedFds = struct {
    const Node = struct {
        fd: linux.fd_t = -1,
        free_next: u32 = free_sentinel,
        chain_next: u32 = free_sentinel,
        generation: u32 = 0,
        in_use: bool = false,
    };

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(*Node),
    free_head: u32,
    active_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity_value: usize) Error!SharedFds {
        if (capacity_value == 0 or capacity_value > free_sentinel)
            return error.InvalidConfig;
        var fds: SharedFds = .{
            .allocator = allocator,
            .nodes = .empty,
            .free_head = free_sentinel,
        };
        errdefer fds.deinitNodes();
        try fds.ensureAvailable(capacity_value);
        return fds;
    }

    pub fn deinit(fds: *SharedFds, allocator: std.mem.Allocator) void {
        std.debug.assert(fds.active_count == 0);
        std.debug.assert(allocator.ptr == fds.allocator.ptr);
        fds.deinitNodes();
        fds.* = undefined;
    }

    pub fn acquire(fds: *SharedFds, fd: linux.fd_t) Error!FdLease {
        try fds.ensureAvailable(1);
        const index = fds.free_head;
        const node = fds.nodes.items[index];
        fds.free_head = node.free_next;
        node.generation = nextGeneration(node.generation);
        node.fd = fd;
        node.chain_next = free_sentinel;
        node.in_use = true;
        fds.active_count += 1;
        return .{ .index = index, .generation = node.generation, .fd = fd };
    }

    /// Releases an entry and transfers descriptor ownership to the caller.
    pub fn take(fds: *SharedFds, lease: FdLease) Error!linux.fd_t {
        try fds.validate(lease);
        const node = fds.nodes.items[lease.index];
        node.in_use = false;
        node.chain_next = free_sentinel;
        node.free_next = fds.free_head;
        fds.free_head = lease.index;
        fds.active_count -= 1;
        return lease.fd;
    }

    pub fn link(fds: *SharedFds, from: FdLease, to: FdLease) Error!void {
        try fds.validate(from);
        try fds.validate(to);
        const node = fds.nodes.items[from.index];
        if (node.chain_next != free_sentinel) return error.InvalidConfig;
        node.chain_next = to.index;
    }

    pub fn nextLease(fds: *SharedFds, lease: FdLease) Error!?FdLease {
        try fds.validate(lease);
        const index = fds.nodes.items[lease.index].chain_next;
        if (index == free_sentinel) return null;
        const node = fds.nodes.items[index];
        if (!node.in_use) return error.StaleLease;
        return .{
            .index = index,
            .generation = node.generation,
            .fd = node.fd,
        };
    }

    pub fn capacity(fds: SharedFds) usize {
        return fds.nodes.items.len;
    }

    pub fn available(fds: SharedFds) usize {
        return fds.capacity() - fds.active_count;
    }

    pub fn ensureAvailable(fds: *SharedFds, count: usize) Error!void {
        if (count > free_sentinel - fds.active_count) return error.CapacityOverflow;
        while (fds.available() < count) try fds.grow();
    }

    fn validate(fds: SharedFds, lease: FdLease) Error!void {
        if (lease.index >= fds.nodes.items.len) return error.StaleLease;
        const node = fds.nodes.items[lease.index];
        if (!node.in_use or node.generation != lease.generation or node.fd != lease.fd)
            return error.StaleLease;
    }

    fn grow(fds: *SharedFds) Error!void {
        if (fds.nodes.items.len >= free_sentinel) return error.CapacityOverflow;
        const node = try fds.allocator.create(Node);
        errdefer fds.allocator.destroy(node);
        const index: u32 = @intCast(fds.nodes.items.len);
        node.* = .{ .free_next = fds.free_head };
        try fds.nodes.append(fds.allocator, node);
        fds.free_head = index;
    }

    fn deinitNodes(fds: *SharedFds) void {
        for (fds.nodes.items) |node| fds.allocator.destroy(node);
        fds.nodes.deinit(fds.allocator);
    }
};

fn nextGeneration(current: u32) u32 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

test "blocks grow and recycle with stable leases" {
    const allocator = std.testing.allocator;
    var blocks = try SharedBlocks.init(allocator, 4096, 2);
    defer blocks.deinit(allocator);

    const first = try blocks.acquire();
    const second = try blocks.acquire();
    try std.testing.expect(first.bytes.ptr != second.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 0), blocks.available());
    const grown = try blocks.acquire();
    try std.testing.expectEqual(@as(usize, 3), blocks.capacity());
    try std.testing.expectEqual(@as(usize, 0), blocks.available());

    try blocks.release(first);
    const reused = try blocks.acquire();
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(reused.generation != first.generation);
    try std.testing.expectError(error.StaleLease, blocks.release(first));

    try blocks.release(reused);
    try blocks.release(second);
    try blocks.release(grown);
    try std.testing.expectEqual(@as(usize, 3), blocks.available());
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
    const grown = try fds.acquire(12);
    try std.testing.expectEqual(@as(usize, 3), fds.capacity());
    try std.testing.expectEqual(@as(linux.fd_t, 10), try fds.take(first));
    const reused = try fds.acquire(13);
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expectError(error.StaleLease, fds.take(first));
    try std.testing.expectEqual(@as(linux.fd_t, 13), try fds.take(reused));
    try std.testing.expectEqual(@as(linux.fd_t, 11), try fds.take(second));
    try std.testing.expectEqual(@as(linux.fd_t, 12), try fds.take(grown));
}
