//! Bounded protocol-independent wl_shm metadata and shared mapping ownership.
//!
//! Unsealed mappings are exposed only through scoped SIGBUS-guarded access.
//! The recovery model follows the MIT-licensed Wayland reference server: a
//! truncation fault replaces the mapping with zero pages and is reported when
//! the outer access ends, while unrelated faults retain their prior action.

const std = @import("std");
const linux = std.os.linux;

const none = std.math.maxInt(u32);

var handler_mutex: std.atomic.Mutex = .unlocked;
var handler_installed = false;
var previous_sigbus: linux.Sigaction = .{
    .handler = .{ .handler = std.posix.SIG.DFL },
    .mask = std.mem.zeroes(linux.sigset_t),
    .flags = 0,
};

threadlocal var active_pool_address: std.atomic.Value(usize) = .init(0);
threadlocal var access_depth: usize = 0;
threadlocal var backing_faulted: std.atomic.Value(bool) = .init(false);

fn ensureSigbusHandler() error{SignalSetupFailed}!void {
    while (!handler_mutex.tryLock()) std.atomic.spinLoopHint();
    defer handler_mutex.unlock();

    var current: linux.Sigaction = undefined;
    if (linux.errno(linux.sigaction(.BUS, null, &current)) != .SUCCESS)
        return error.SignalSetupFailed;
    if (handler_installed) {
        if (current.handler.sigaction != handleSigbus)
            return error.SignalSetupFailed;
        return;
    }
    previous_sigbus = current;
    const action: linux.Sigaction = .{
        .handler = .{ .sigaction = handleSigbus },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = linux.SA.SIGINFO | linux.SA.NODEFER,
    };
    if (linux.errno(linux.sigaction(.BUS, &action, null)) != .SUCCESS)
        return error.SignalSetupFailed;
    handler_installed = true;
}

fn handleSigbus(_: linux.SIG, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const pool_address = active_pool_address.load(.acquire);
    if (pool_address != 0) {
        const pool: *PoolNode = @ptrFromInt(pool_address);
        const address = @intFromPtr(info.fields.sigfault.addr);
        const start = @intFromPtr(pool.mapping.ptr);
        const end = std.math.add(usize, start, pool.mapping.len) catch 0;
        if (end != 0 and address >= start and address < end) {
            backing_faulted.store(true, .release);
            const result = linux.mmap(pool.mapping.ptr, pool.mapping.len, .{
                .READ = true,
                .WRITE = true,
            }, .{
                .TYPE = .PRIVATE,
                .FIXED = true,
                .ANONYMOUS = true,
            }, -1, 0);
            if (linux.errno(result) == .SUCCESS and result == start) return;
        }
    }

    _ = linux.sigaction(.BUS, &previous_sigbus, null);
    _ = linux.tkill(linux.gettid(), .BUS);
}

pub const Error = error{
    InvalidConfig,
    InvalidPoolSize,
    PoolTooLarge,
    InvalidResize,
    InvalidDimensions,
    InvalidStride,
    OutOfBounds,
    SizeOverflow,
};

pub const StoreError = Error || std.mem.Allocator.Error || std.posix.MMapError ||
    std.posix.MRemapError || error{
    Exhausted,
    StalePool,
    StaleBuffer,
    StalePin,
    ResourceDestroyed,
    ResizePending,
    UnsafeAccess,
    DestinationTooSmall,
    InvalidCompletion,
    CopyFailed,
    ShortRead,
    SignalSetupFailed,
    AccessConflict,
    InvalidBacking,
};

/// Compositor-supplied metadata for an advertised wl_shm format. Keeping the
/// byte width beside the protocol value permits stricter stride validation for
/// both core and compositor-added formats.
pub const Format = struct {
    value: u32,
    bytes_per_pixel: u8,
};

pub const Limits = struct {
    max_pool_bytes: usize,

    pub fn validate(limits: Limits) Error!void {
        if (limits.max_pool_bytes == 0 or
            limits.max_pool_bytes > std.math.maxInt(i32))
            return error.InvalidConfig;
    }
};

pub const Buffer = struct {
    offset: usize,
    width: u32,
    height: u32,
    stride: usize,
    format: Format,

    /// Bytes conservatively reserved in the pool, including final-row
    /// padding. This matches established compositor behavior and makes sibling
    /// overlap checks possible without repeating arithmetic.
    extent: usize,

    pub fn end(buffer: Buffer) usize {
        return buffer.offset + buffer.extent;
    }
};

pub fn createPool(limits: Limits, requested_size: i32) Error!usize {
    try limits.validate();
    if (requested_size <= 0) return error.InvalidPoolSize;
    const size: usize = @intCast(requested_size);
    if (size > limits.max_pool_bytes) return error.PoolTooLarge;
    return size;
}

pub fn resizePool(limits: Limits, current_size: usize, requested_size: i32) Error!usize {
    const size = try createPool(limits, requested_size);
    if (size < current_size) return error.InvalidResize;
    return size;
}

/// Validates immutable wl_buffer metadata against one declared pool size.
/// Every multiplication and addition is checked before state publication.
pub fn createBuffer(
    pool_size: usize,
    format: Format,
    offset_value: i32,
    width_value: i32,
    height_value: i32,
    stride_value: i32,
) Error!Buffer {
    if (format.bytes_per_pixel == 0) return error.InvalidConfig;
    if (offset_value < 0) return error.OutOfBounds;
    if (width_value <= 0 or height_value <= 0) return error.InvalidDimensions;
    if (stride_value <= 0) return error.InvalidStride;

    const offset: usize = @intCast(offset_value);
    const width: usize = @intCast(width_value);
    const height: usize = @intCast(height_value);
    const stride: usize = @intCast(stride_value);
    const row_bytes = std.math.mul(
        usize,
        width,
        format.bytes_per_pixel,
    ) catch return error.SizeOverflow;
    if (stride < row_bytes) return error.InvalidStride;
    const extent = std.math.mul(usize, stride, height) catch
        return error.SizeOverflow;
    const end = std.math.add(usize, offset, extent) catch
        return error.SizeOverflow;
    if (end > pool_size) return error.OutOfBounds;

    return .{
        .offset = offset,
        .width = @intCast(width),
        .height = @intCast(height),
        .stride = stride,
        .format = format,
        .extent = extent,
    };
}

pub const PoolToken = struct {
    index: u32,
    generation: u32,
};

pub const BufferToken = struct {
    index: u32,
    generation: u32,
};

const PoolNode = struct {
    generation: u32 = 1,
    next_free: u32 = none,
    active: bool = false,
    resource_alive: bool = false,
    fd: linux.fd_t = -1,
    mapping: []align(std.heap.page_size_min) u8 = undefined,
    declared_size: usize = 0,
    pending_size: usize = 0,
    buffer_count: usize = 0,
    pin_count: usize = 0,
    sealed_direct: bool = false,
    invalid_backing: bool = false,
};

const BufferNode = struct {
    generation: u32 = 1,
    next_free: u32 = none,
    active: bool = false,
    pool: PoolToken = undefined,
    metadata: Buffer = undefined,
};

const PinNode = struct {
    generation: u32 = 1,
    next_free: u32 = none,
    active: bool = false,
    pool: PoolToken = undefined,
    metadata: Buffer = undefined,
};

const PinToken = struct {
    index: u32,
    generation: u32,
};

pub const PoolInfo = struct {
    mapped_size: usize,
    declared_size: usize,
    pending_size: ?usize,
    buffer_count: usize,
    pin_count: usize,
    resource_alive: bool,
    sealed_direct: bool,
};

/// A compositor-wide bounded store. Protocol pool resources, child buffers,
/// and importer pins hold independent references to one mapping. Capacities
/// are initial reserves; individually allocated nodes keep addresses stable as
/// the index tables grow.
pub const Store = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    pools: std.ArrayList(*PoolNode),
    buffers: std.ArrayList(*BufferNode),
    pins: std.ArrayList(*PinNode),
    pool_free: u32,
    buffer_free: u32,
    pin_free: u32,
    active_pools: usize = 0,
    active_buffers: usize = 0,
    active_pins: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
        pool_capacity: usize,
        buffer_capacity: usize,
    ) StoreError!Store {
        try limits.validate();
        if (pool_capacity == 0 or buffer_capacity == 0 or
            pool_capacity >= none or buffer_capacity >= none)
            return error.InvalidConfig;
        var store: Store = .{
            .allocator = allocator,
            .limits = limits,
            .pools = .empty,
            .buffers = .empty,
            .pins = .empty,
            .pool_free = none,
            .buffer_free = none,
            .pin_free = none,
        };
        errdefer store.deinitNodes();
        for (0..pool_capacity) |_| try store.growPool();
        for (0..buffer_capacity) |_| try store.growBuffer();
        for (0..buffer_capacity) |_| try store.growPin();
        return store;
    }

    pub fn deinit(store: *Store, allocator: std.mem.Allocator) void {
        std.debug.assert(store.active_pools == 0);
        std.debug.assert(store.active_buffers == 0);
        std.debug.assert(store.active_pins == 0);
        std.debug.assert(allocator.ptr == store.allocator.ptr);
        store.deinitNodes();
        store.* = undefined;
    }

    /// Takes ownership of `fd` on success. The descriptor remains open for
    /// growth validation and closes with the final mapping reference.
    pub fn addPool(store: *Store, fd: linux.fd_t, requested_size: i32) StoreError!PoolToken {
        if (store.pool_free == none) try store.growPool();
        const size = try createPool(store.limits, requested_size);
        const mapping = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        const index = store.pool_free;
        const node = store.pools.items[index];
        const generation = node.generation;
        store.pool_free = node.next_free;
        node.* = .{
            .generation = generation,
            .active = true,
            .resource_alive = true,
            .fd = fd,
            .mapping = mapping,
            .declared_size = size,
            .sealed_direct = fileCannotShrinkBelow(fd, size),
        };
        store.active_pools += 1;
        return .{ .index = index, .generation = generation };
    }

    pub fn destroyPoolResource(store: *Store, token: PoolToken) StoreError!void {
        const node = try store.resolvePool(token);
        if (!node.resource_alive) return error.ResourceDestroyed;
        node.resource_alive = false;
        store.releasePoolIfUnused(token.index);
    }

    pub fn resize(store: *Store, token: PoolToken, requested_size: i32) StoreError!void {
        const node = try store.resolvePool(token);
        if (!node.resource_alive) return error.ResourceDestroyed;
        const size = try resizePool(store.limits, node.declared_size, requested_size);
        if (size == node.declared_size) return;
        if (node.pin_count != 0) {
            node.declared_size = size;
            node.pending_size = size;
            return;
        }
        const mapping = try remap(node.mapping, size);
        node.mapping = mapping;
        node.declared_size = size;
        node.sealed_direct = fileCannotShrinkBelow(node.fd, size);
    }

    pub fn addBuffer(
        store: *Store,
        pool_token: PoolToken,
        format: Format,
        offset: i32,
        width: i32,
        height: i32,
        stride: i32,
    ) StoreError!BufferToken {
        const pool = try store.resolvePool(pool_token);
        if (!pool.resource_alive) return error.ResourceDestroyed;
        if (store.buffer_free == none) try store.growBuffer();
        const metadata = try createBuffer(
            pool.declared_size,
            format,
            offset,
            width,
            height,
            stride,
        );
        const index = store.buffer_free;
        const node = store.buffers.items[index];
        const generation = node.generation;
        store.buffer_free = node.next_free;
        node.* = .{
            .generation = generation,
            .active = true,
            .pool = pool_token,
            .metadata = metadata,
        };
        pool.buffer_count += 1;
        store.active_buffers += 1;
        return .{ .index = index, .generation = generation };
    }

    pub fn destroyBuffer(store: *Store, token: BufferToken) StoreError!void {
        const node = try store.resolveBuffer(token);
        const pool_index = node.pool.index;
        const pool = try store.resolvePool(node.pool);
        pool.buffer_count -= 1;
        node.active = false;
        node.generation = nextGeneration(node.generation);
        node.next_free = store.buffer_free;
        store.buffer_free = token.index;
        store.active_buffers -= 1;
        store.releasePoolIfUnused(pool_index);
    }

    pub fn poolInfo(store: *Store, token: PoolToken) StoreError!PoolInfo {
        const node = try store.resolvePool(token);
        return .{
            .mapped_size = node.mapping.len,
            .declared_size = node.declared_size,
            .pending_size = if (node.pending_size == 0) null else node.pending_size,
            .buffer_count = node.buffer_count,
            .pin_count = node.pin_count,
            .resource_alive = node.resource_alive,
            .sealed_direct = node.sealed_direct,
        };
    }

    pub fn bufferInfo(store: *Store, token: BufferToken) StoreError!Buffer {
        return (try store.resolveBuffer(token)).metadata;
    }

    pub const Pin = struct {
        token: PinToken,
    };

    pub fn pin(store: *Store, token: BufferToken) StoreError!Pin {
        const buffer = try store.resolveBuffer(token);
        const pool = try store.resolvePool(buffer.pool);
        if (pool.pending_size != 0) return error.ResizePending;
        if (store.pin_free == none) try store.growPin();
        const pin_index = store.pin_free;
        const pin_node = store.pins.items[pin_index];
        const pin_generation = pin_node.generation;
        store.pin_free = pin_node.next_free;
        pin_node.* = .{
            .generation = pin_generation,
            .active = true,
            .pool = buffer.pool,
            .metadata = buffer.metadata,
        };
        pool.pin_count += 1;
        store.active_pins += 1;
        return .{
            .token = .{ .index = pin_index, .generation = pin_generation },
        };
    }

    /// Returns a zero-copy read-only slice only while this pin remains active
    /// and file seals make truncation faults impossible for the full mapping.
    pub fn bytes(store: *Store, pin_value: Pin) StoreError![]const u8 {
        const pin_node = try store.resolvePin(pin_value.token);
        const pool = try store.resolvePool(pin_node.pool);
        if (!pool.sealed_direct) return error.UnsafeAccess;
        return pool.mapping[pin_node.metadata.offset..pin_node.metadata.end()];
    }

    pub const Access = struct {
        store: *Store,
        pin: Pin,
        pool: *PoolNode,
        guarded: bool,
        active: bool = true,
        bytes: []const u8,

        /// Ends access and invalidates `bytes`. If backing truncation faulted
        /// during the guarded scope, the mapping has already been replaced by
        /// zero pages and this reports the client-owned backing as invalid.
        pub fn end(self: *Access) StoreError!void {
            if (!self.active) return error.StalePin;
            _ = try self.store.resolvePin(self.pin.token);
            if (self.guarded) {
                std.debug.assert(
                    active_pool_address.load(.acquire) == @intFromPtr(self.pool) and
                        access_depth > 0,
                );
                access_depth -= 1;
                if (access_depth == 0) {
                    _ = active_pool_address.swap(0, .seq_cst);
                    if (backing_faulted.swap(false, .seq_cst)) {
                        self.pool.invalid_backing = true;
                        self.active = false;
                        self.bytes = &.{};
                        return error.InvalidBacking;
                    }
                }
            }
            self.active = false;
            self.bytes = &.{};
        }
    };

    /// Begins scoped direct access to a pinned buffer. Ordinary unsealed pools
    /// are protected against concurrent truncation by a process-wide SIGBUS
    /// guard; shrink-sealed pools need no signal scope. Nested access on one
    /// thread is allowed only for the same pool.
    pub fn access(store: *Store, pin_value: Pin) StoreError!Access {
        const pin_node = try store.resolvePin(pin_value.token);
        const pool = try store.resolvePool(pin_node.pool);
        if (pool.invalid_backing) return error.InvalidBacking;
        const guarded = !pool.sealed_direct;
        if (guarded) {
            const pool_address = active_pool_address.load(.acquire);
            if (pool_address != 0 and pool_address != @intFromPtr(pool))
                return error.AccessConflict;
            try ensureSigbusHandler();
            if (pool_address == 0) {
                backing_faulted.store(false, .seq_cst);
                _ = active_pool_address.swap(@intFromPtr(pool), .seq_cst);
            }
            access_depth += 1;
        }
        return .{
            .store = store,
            .pin = pin_value,
            .pool = pool,
            .guarded = guarded,
            .bytes = pool.mapping[pin_node.metadata.offset..pin_node.metadata.end()],
        };
    }

    pub fn unpin(store: *Store, pin_value: Pin) StoreError!void {
        const pin_node = try store.resolvePin(pin_value.token);
        const pool_token = pin_node.pool;
        const pool_index = pool_token.index;
        const pool = try store.resolvePool(pool_token);
        pin_node.active = false;
        pin_node.generation = nextGeneration(pin_node.generation);
        pin_node.next_free = store.pin_free;
        store.pin_free = pin_value.token.index;
        store.active_pins -= 1;
        pool.pin_count -= 1;
        if (pool.pin_count == 0 and pool.pending_size != 0) {
            const size = pool.pending_size;
            const mapping = remap(pool.mapping, size) catch |err| {
                store.releasePoolIfUnused(pool_index);
                return err;
            };
            pool.mapping = mapping;
            pool.pending_size = 0;
            pool.sealed_direct = fileCannotShrinkBelow(pool.fd, size);
        }
        store.releasePoolIfUnused(pool_index);
    }

    pub const Copy = struct {
        pin: Pin,
        destination: []u8,
        expected_len: usize,
        user_data: u64,
    };

    /// Queues, but does not submit, one positional read into caller-owned
    /// memory. This is the SIGBUS-safe path for ordinary unsealed pools and can
    /// be batched with the consumer's other SQEs on a borrowed ring.
    pub fn prepareCopy(
        store: *Store,
        ring: *linux.IoUring,
        token: BufferToken,
        destination: []u8,
        user_data: u64,
    ) !Copy {
        const pin_value = try store.pin(token);
        errdefer store.unpin(pin_value) catch unreachable;
        const pin_node = try store.resolvePin(pin_value.token);
        if (destination.len < pin_node.metadata.extent)
            return error.DestinationTooSmall;
        const pool = try store.resolvePool(pin_node.pool);
        _ = try ring.read(
            user_data,
            pool.fd,
            .{ .buffer = destination[0..pin_node.metadata.extent] },
            pin_node.metadata.offset,
        );
        return .{
            .pin = pin_value,
            .destination = destination,
            .expected_len = pin_node.metadata.extent,
            .user_data = user_data,
        };
    }

    /// Completes a copy selected by the caller's CQE router and releases its
    /// mapping pin. Short reads safely report concurrent backing truncation.
    pub fn completeCopy(
        store: *Store,
        copy: Copy,
        completion: linux.io_uring_cqe,
    ) StoreError![]const u8 {
        if (completion.user_data != copy.user_data) return error.InvalidCompletion;
        const result = completion.res;
        try store.unpin(copy.pin);
        if (result < 0) return error.CopyFailed;
        const actual: usize = @intCast(result);
        if (actual != copy.expected_len) return error.ShortRead;
        return copy.destination[0..actual];
    }

    fn resolvePool(store: *Store, token: PoolToken) StoreError!*PoolNode {
        if (token.index >= store.pools.items.len) return error.StalePool;
        const node = store.pools.items[token.index];
        if (!node.active or node.generation != token.generation) return error.StalePool;
        return node;
    }

    fn resolveBuffer(store: *Store, token: BufferToken) StoreError!*BufferNode {
        if (token.index >= store.buffers.items.len) return error.StaleBuffer;
        const node = store.buffers.items[token.index];
        if (!node.active or node.generation != token.generation) return error.StaleBuffer;
        return node;
    }

    fn resolvePin(store: *Store, token: PinToken) StoreError!*PinNode {
        if (token.index >= store.pins.items.len) return error.StalePin;
        const node = store.pins.items[token.index];
        if (!node.active or node.generation != token.generation) return error.StalePin;
        return node;
    }

    fn releasePoolIfUnused(store: *Store, index: u32) void {
        const node = store.pools.items[index];
        if (node.resource_alive or node.buffer_count != 0 or node.pin_count != 0) return;
        std.posix.munmap(node.mapping);
        _ = linux.close(node.fd);
        node.active = false;
        node.generation = nextGeneration(node.generation);
        node.next_free = store.pool_free;
        store.pool_free = index;
        store.active_pools -= 1;
    }

    fn growPool(store: *Store) std.mem.Allocator.Error!void {
        if (store.pools.items.len >= none) return error.OutOfMemory;
        const node = try store.allocator.create(PoolNode);
        errdefer store.allocator.destroy(node);
        node.* = .{ .next_free = store.pool_free };
        try store.pools.append(store.allocator, node);
        store.pool_free = @intCast(store.pools.items.len - 1);
    }

    fn growBuffer(store: *Store) std.mem.Allocator.Error!void {
        if (store.buffers.items.len >= none) return error.OutOfMemory;
        const node = try store.allocator.create(BufferNode);
        errdefer store.allocator.destroy(node);
        node.* = .{ .next_free = store.buffer_free };
        try store.buffers.append(store.allocator, node);
        store.buffer_free = @intCast(store.buffers.items.len - 1);
    }

    fn growPin(store: *Store) std.mem.Allocator.Error!void {
        if (store.pins.items.len >= none) return error.OutOfMemory;
        const node = try store.allocator.create(PinNode);
        errdefer store.allocator.destroy(node);
        node.* = .{ .next_free = store.pin_free };
        try store.pins.append(store.allocator, node);
        store.pin_free = @intCast(store.pins.items.len - 1);
    }

    fn deinitNodes(store: *Store) void {
        for (store.pins.items) |node| store.allocator.destroy(node);
        for (store.buffers.items) |node| store.allocator.destroy(node);
        for (store.pools.items) |node| store.allocator.destroy(node);
        store.pins.deinit(store.allocator);
        store.buffers.deinit(store.allocator);
        store.pools.deinit(store.allocator);
    }
};

fn remap(
    mapping: []align(std.heap.page_size_min) u8,
    size: usize,
) std.posix.MRemapError![]align(std.heap.page_size_min) u8 {
    return std.posix.mremap(mapping.ptr, mapping.len, size, .{ .MAYMOVE = true }, null);
}

fn fileCannotShrinkBelow(fd: linux.fd_t, size: usize) bool {
    const seals_result = linux.fcntl(fd, linux.F.GET_SEALS, 0);
    if (linux.errno(seals_result) != .SUCCESS or
        seals_result & linux.F.SEAL_SHRINK == 0)
        return false;
    var stat: linux.Statx = undefined;
    const stat_result = linux.statx(
        fd,
        "",
        linux.AT.EMPTY_PATH | linux.AT.STATX_DONT_SYNC,
        .{ .SIZE = true },
        &stat,
    );
    return linux.errno(stat_result) == .SUCCESS and stat.mask.SIZE and stat.size >= size;
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

test "store grows pools buffers and pins beyond initial capacities" {
    var store = try Store.init(
        std.testing.allocator,
        .{ .max_pool_bytes = 4096 },
        1,
        1,
    );
    defer store.deinit(std.testing.allocator);

    const first_pool = try store.addPool(try testMemfd(4096, true), 4096);
    const second_pool = try store.addPool(try testMemfd(4096, true), 4096);
    const format: Format = .{ .value = 0, .bytes_per_pixel = 4 };
    const first_buffer = try store.addBuffer(first_pool, format, 0, 2, 2, 8);
    const second_buffer = try store.addBuffer(second_pool, format, 0, 2, 2, 8);
    const first_pin = try store.pin(first_buffer);
    const second_pin = try store.pin(second_buffer);

    try std.testing.expectEqual(@as(usize, 2), store.pools.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.pins.items.len);
    try std.testing.expectEqual(@as(usize, 16), (try store.bytes(first_pin)).len);
    try std.testing.expectEqual(@as(usize, 16), (try store.bytes(second_pin)).len);

    try store.unpin(first_pin);
    try store.unpin(second_pin);
    try store.destroyBuffer(first_buffer);
    try store.destroyBuffer(second_buffer);
    try store.destroyPoolResource(first_pool);
    try store.destroyPoolResource(second_pool);
}

test "shared mappings outlive resources and defer growth while pinned" {
    var store = try Store.init(
        std.testing.allocator,
        .{ .max_pool_bytes = 8192 },
        1,
        2,
    );
    defer store.deinit(std.testing.allocator);
    const fd = try testMemfd(8192, true);
    const pool = try store.addPool(fd, 4096);
    const first = try store.addBuffer(
        pool,
        .{ .value = 0, .bytes_per_pixel = 4 },
        0,
        2,
        2,
        8,
    );
    const pin_value = try store.pin(first);
    try std.testing.expectEqual(@as(usize, 16), (try store.bytes(pin_value)).len);

    try store.resize(pool, 8192);
    const deferred = try store.poolInfo(pool);
    try std.testing.expectEqual(@as(usize, 4096), deferred.mapped_size);
    try std.testing.expectEqual(@as(usize, 8192), deferred.declared_size);
    try std.testing.expectEqual(@as(?usize, 8192), deferred.pending_size);
    try std.testing.expectError(error.ResizePending, store.pin(first));
    try store.unpin(pin_value);
    const grown = try store.poolInfo(pool);
    try std.testing.expectEqual(@as(usize, 8192), grown.mapped_size);
    try std.testing.expectEqual(@as(?usize, null), grown.pending_size);
    try std.testing.expect(grown.sealed_direct);

    const second = try store.addBuffer(
        pool,
        .{ .value = 0, .bytes_per_pixel = 4 },
        4096,
        2,
        2,
        8,
    );
    try store.destroyPoolResource(pool);
    try std.testing.expect(!(try store.poolInfo(pool)).resource_alive);
    try std.testing.expectError(error.ResourceDestroyed, store.addBuffer(
        pool,
        .{ .value = 0, .bytes_per_pixel = 4 },
        0,
        1,
        1,
        4,
    ));
    try store.destroyBuffer(first);
    try store.destroyBuffer(second);
    try std.testing.expectError(error.StalePool, store.poolInfo(pool));
    try std.testing.expectError(error.StaleBuffer, store.bufferInfo(first));

    const replacement_pool = try store.addPool(try testMemfd(4096, true), 4096);
    try std.testing.expectEqual(pool.index, replacement_pool.index);
    try std.testing.expect(pool.generation != replacement_pool.generation);
    const replacement_buffer = try store.addBuffer(
        replacement_pool,
        .{ .value = 0, .bytes_per_pixel = 4 },
        0,
        1,
        1,
        4,
    );
    try std.testing.expectEqual(second.index, replacement_buffer.index);
    try std.testing.expect(second.generation != replacement_buffer.generation);
    try store.destroyBuffer(replacement_buffer);
    try store.destroyPoolResource(replacement_pool);
}

test "pins retain destroyed unsealed pools without exposing raw bytes" {
    var store = try Store.init(
        std.testing.allocator,
        .{ .max_pool_bytes = 4096 },
        1,
        1,
    );
    defer store.deinit(std.testing.allocator);
    const fd = try testMemfd(4096, false);
    const payload = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectEqual(
        @as(usize, payload.len),
        linux.write(fd, &payload, payload.len),
    );
    const pool = try store.addPool(fd, 4096);
    const buffer = try store.addBuffer(
        pool,
        .{ .value = 0, .bytes_per_pixel = 4 },
        0,
        1,
        1,
        4,
    );
    const pin_value = try store.pin(buffer);
    try std.testing.expectError(error.UnsafeAccess, store.bytes(pin_value));
    try store.unpin(pin_value);

    var ring = try linux.IoUring.init(4, 0);
    defer ring.deinit();
    var destination: [4]u8 = undefined;
    var undersized: [3]u8 = undefined;
    try std.testing.expectError(
        error.DestinationTooSmall,
        store.prepareCopy(&ring, buffer, &undersized, 0xff),
    );
    try std.testing.expectEqual(@as(usize, 0), store.active_pins);
    const copy = try store.prepareCopy(&ring, buffer, &destination, 0x100);
    _ = try ring.submit();
    const copied = try store.completeCopy(copy, try ring.copy_cqe());
    try std.testing.expectEqualSlices(u8, &payload, copied);

    const truncated_copy = try store.prepareCopy(&ring, buffer, &destination, 0x101);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, 0)));
    _ = try ring.submit();
    try std.testing.expectError(
        error.ShortRead,
        store.completeCopy(truncated_copy, try ring.copy_cqe()),
    );
    const retained = try store.pin(buffer);
    try store.destroyPoolResource(pool);
    try store.destroyBuffer(buffer);
    try std.testing.expectEqual(@as(usize, 1), store.active_pools);
    try store.unpin(retained);
    try std.testing.expectEqual(@as(usize, 0), store.active_pools);
    try std.testing.expectError(error.StalePool, store.poolInfo(pool));
    try std.testing.expectError(error.StalePin, store.unpin(retained));
}

test "guarded access converts unsealed backing truncation into an error" {
    var store = try Store.init(
        std.testing.allocator,
        .{ .max_pool_bytes = 4096 },
        1,
        1,
    );
    defer store.deinit(std.testing.allocator);
    const fd = try testMemfd(4096, false);
    const payload = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectEqual(
        @as(usize, payload.len),
        linux.write(fd, &payload, payload.len),
    );
    const pool = try store.addPool(fd, 4096);
    const buffer = try store.addBuffer(
        pool,
        .{ .value = 0, .bytes_per_pixel = 4 },
        0,
        1,
        1,
        4,
    );
    const pin_value = try store.pin(buffer);

    var readable = try store.access(pin_value);
    try std.testing.expectEqualSlices(u8, &payload, readable.bytes[0..payload.len]);
    try readable.end();

    var truncated = try store.access(pin_value);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, 0)));
    const first: *const volatile u8 = @ptrCast(truncated.bytes.ptr);
    try std.testing.expectEqual(@as(u8, 0), first.*);
    try std.testing.expectError(error.InvalidBacking, truncated.end());
    try std.testing.expectError(error.InvalidBacking, store.access(pin_value));

    try store.unpin(pin_value);
    try store.destroyBuffer(buffer);
    try store.destroyPoolResource(pool);
}

fn testMemfd(size: usize, sealed: bool) !linux.fd_t {
    const flags: u32 = linux.MFD.CLOEXEC |
        if (sealed) @as(u32, linux.MFD.ALLOW_SEALING) else 0;
    const result = linux.memfd_create("wayring-shm-test", flags);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS)
        return error.SystemCallFailed;
    if (sealed and linux.errno(linux.fcntl(
        fd,
        linux.F.ADD_SEALS,
        linux.F.SEAL_SHRINK,
    )) != .SUCCESS) return error.SystemCallFailed;
    return fd;
}

test "pool creation and growth enforce configured bounds" {
    const limits: Limits = .{ .max_pool_bytes = 4096 };
    try std.testing.expectError(error.InvalidPoolSize, createPool(limits, 0));
    try std.testing.expectError(error.PoolTooLarge, createPool(limits, 4097));
    try std.testing.expectEqual(@as(usize, 4096), try createPool(limits, 4096));
    try std.testing.expectError(error.InvalidResize, resizePool(limits, 4096, 2048));
    try std.testing.expectEqual(@as(usize, 4096), try resizePool(limits, 2048, 4096));
    try std.testing.expectError(error.InvalidConfig, createPool(.{
        .max_pool_bytes = 0,
    }, 1));
}

test "buffer validation is format-aware and overflow-safe" {
    const argb8888: Format = .{ .value = 0, .bytes_per_pixel = 4 };
    const buffer = try createBuffer(4096, argb8888, 16, 8, 4, 40);
    try std.testing.expectEqual(@as(usize, 160), buffer.extent);
    try std.testing.expectEqual(@as(usize, 176), buffer.end());

    try std.testing.expectError(
        error.InvalidStride,
        createBuffer(4096, argb8888, 0, 8, 4, 31),
    );
    try std.testing.expectError(
        error.OutOfBounds,
        createBuffer(4096, argb8888, 4000, 8, 4, 32),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        createBuffer(4096, argb8888, 0, 0, 4, 32),
    );
    try std.testing.expectError(
        error.OutOfBounds,
        createBuffer(4096, argb8888, -1, 8, 4, 32),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        createBuffer(4096, .{ .value = 1, .bytes_per_pixel = 0 }, 0, 1, 1, 1),
    );
}
