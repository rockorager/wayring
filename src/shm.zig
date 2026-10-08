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
var handler_installed: std.atomic.Value(bool) = .init(false);
var previous_sigbus: linux.Sigaction = .{
    .handler = .{ .handler = std.posix.SIG.DFL },
    .mask = std.mem.zeroes(linux.sigset_t),
    .flags = 0,
};

threadlocal var active_pool_address: std.atomic.Value(usize) = .init(0);
threadlocal var access_depth: usize = 0;
threadlocal var backing_faulted: std.atomic.Value(bool) = .init(false);

fn ensureSigbusHandler() error{SignalSetupFailed}!void {
    if (!handler_installed.load(.acquire)) {
        while (!handler_mutex.tryLock()) std.atomic.spinLoopHint();
        defer handler_mutex.unlock();
        if (!handler_installed.load(.monotonic)) {
            var current: linux.Sigaction = undefined;
            if (linux.errno(linux.sigaction(.BUS, null, &current)) != .SUCCESS)
                return error.SignalSetupFailed;
            previous_sigbus = current;
            const action: linux.Sigaction = .{
                .handler = .{ .sigaction = handleSigbus },
                .mask = std.mem.zeroes(linux.sigset_t),
                .flags = linux.SA.SIGINFO | linux.SA.NODEFER,
            };
            if (linux.errno(linux.sigaction(.BUS, &action, null)) != .SUCCESS)
                return error.SignalSetupFailed;
            handler_installed.store(true, .release);
            return;
        }
    }

    // Validation remains per-scope, but does not need to serialize readers.
    // The installation publishes previous_sigbus once and never changes it.
    var current: linux.Sigaction = undefined;
    if (linux.errno(linux.sigaction(.BUS, null, &current)) != .SUCCESS or
        current.handler.sigaction != handleSigbus)
        return error.SignalSetupFailed;
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
    AccessActive,
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
    access_count: usize = 0,
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
        _ = allocator; // Retained for compatibility; allocation ownership is stored.
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
        if (size == node.declared_size) {
            if (node.pin_count == 0) try applyPendingResize(node);
            return;
        }
        if (node.pin_count != 0) {
            node.declared_size = size;
            node.pending_size = size;
            return;
        }
        const mapping = try remap(node.mapping, size);
        node.mapping = mapping;
        node.declared_size = size;
        node.pending_size = 0;
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
        if (pool.pending_size != 0) {
            if (pool.pin_count != 0) return error.ResizePending;
            try applyPendingResize(pool);
        }
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
    /// Backing replaced after an earlier truncation fault stays invalid even
    /// if the client later restores and seals the file.
    pub fn bytes(store: *Store, pin_value: Pin) StoreError![]const u8 {
        const pin_node = try store.resolvePin(pin_value.token);
        const pool = try store.resolvePool(pin_node.pool);
        if (pool.invalid_backing) return error.InvalidBacking;
        if (!pool.sealed_direct) return error.UnsafeAccess;
        return pool.mapping[pin_node.metadata.offset..pin_node.metadata.end()];
    }

    fn AccessType(comptime writable: bool) type {
        return struct {
            const Self = @This();

            store: *Store,
            pin: Pin,
            pool: *PoolNode,
            guarded: bool,
            active: bool = true,
            bytes: if (writable) []u8 else []const u8,

            /// Ends access and invalidates `bytes`. If backing truncation faulted
            /// during the guarded scope, the mapping has already been replaced by
            /// zero pages and this reports the client-owned backing as invalid.
            pub fn end(self: *Self) StoreError!void {
                if (!self.active) return error.StalePin;
                const pin_node = try self.store.resolvePin(self.pin.token);
                std.debug.assert(pin_node.access_count > 0);
                pin_node.access_count -= 1;
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
    }

    pub const Access = AccessType(false);
    pub const WriteAccess = AccessType(true);

    /// Begins scoped direct access to a pinned buffer. Ordinary unsealed pools
    /// are protected against concurrent truncation by a process-wide SIGBUS
    /// guard; shrink-sealed pools need no signal scope. Nested access on one
    /// thread is allowed only for the same pool. End every access exactly once,
    /// on the originating thread, before unpinning; do not copy active scopes.
    pub fn access(store: *Store, pin_value: Pin) StoreError!Access {
        return store.beginAccess(pin_value, false);
    }

    /// Begins scoped writable access to a pinned destination buffer. This has
    /// the same truncation guard and same-pool nesting rules as read access.
    pub fn writeAccess(store: *Store, pin_value: Pin) StoreError!WriteAccess {
        return store.beginAccess(pin_value, true);
    }

    fn beginAccess(
        store: *Store,
        pin_value: Pin,
        comptime writable: bool,
    ) StoreError!AccessType(writable) {
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
        pin_node.access_count += 1;
        return .{
            .store = store,
            .pin = pin_value,
            .pool = pool,
            .guarded = guarded,
            .bytes = pool.mapping[pin_node.metadata.offset..pin_node.metadata.end()],
        };
    }

    /// Consumes the pin before applying deferred growth. A remap failure is
    /// returned with the growth still pending, but the completed copy pin is
    /// not retained and must not be unpinned again. AccessActive instead leaves
    /// the pin unchanged: end its scoped accesses before retrying unpin.
    pub fn unpin(store: *Store, pin_value: Pin) StoreError!void {
        const pin_node = try store.resolvePin(pin_value.token);
        if (pin_node.access_count != 0) return error.AccessActive;
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
            applyPendingResize(pool) catch |err| {
                store.releasePoolIfUnused(pool_index);
                return err;
            };
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

fn applyPendingResize(node: *PoolNode) std.posix.MRemapError!void {
    const size = node.pending_size;
    if (size == 0) return;
    const mapping = try remap(node.mapping, size);
    node.mapping = mapping;
    node.pending_size = 0;
    node.sealed_direct = fileCannotShrinkBelow(node.fd, size);
}

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

test "SIGBUS handler initializes concurrently and rejects replacement" {
    const Worker = struct {
        fn run(ready: *std.atomic.Value(usize), go: *std.atomic.Value(bool), failure: *?anyerror) void {
            _ = ready.fetchAdd(1, .release);
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            for (0..1000) |_| ensureSigbusHandler() catch |err| {
                failure.* = err;
                return;
            };
        }
    };
    var ready: std.atomic.Value(usize) = .init(0);
    var go: std.atomic.Value(bool) = .init(false);
    var failures = [_]?anyerror{null} ** 2;
    var threads: [2]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        go.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads, &failures) |*thread, *failure| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &ready, &go, failure });
        spawned += 1;
    }
    while (ready.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    go.store(true, .release);
    for (threads) |thread| thread.join();
    spawned = 0;
    for (failures) |failure| if (failure) |err| return err;

    var store = try Store.init(std.testing.allocator, .{ .max_pool_bytes = 4096 }, 1, 1);
    defer store.deinit(std.testing.allocator);
    const pool = try store.addPool(try testMemfd(4096, false), 4096);
    defer store.destroyPoolResource(pool) catch unreachable;
    const buffer = try store.addBuffer(pool, .{ .value = 0, .bytes_per_pixel = 4 }, 0, 1, 1, 4);
    defer store.destroyBuffer(buffer) catch unreachable;
    const pin_value = try store.pin(buffer);
    defer store.unpin(pin_value) catch unreachable;
    var outer = try store.access(pin_value);
    defer outer.end() catch unreachable;

    const replacement: linux.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    var original: linux.Sigaction = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sigaction(.BUS, &replacement, &original)));
    defer std.debug.assert(linux.errno(linux.sigaction(.BUS, &original, null)) == .SUCCESS);
    try std.testing.expectError(error.SignalSetupFailed, store.access(pin_value));
    try std.testing.expectError(error.SignalSetupFailed, store.writeAccess(pin_value));
    try std.testing.expectEqual(@as(usize, 1), (try store.resolvePin(pin_value.token)).access_count);
    try std.testing.expectEqual(@as(usize, 1), access_depth);
}

test "store accepts stateless and stateful allocators" {
    inline for (.{ std.heap.page_allocator, std.testing.allocator }) |allocator| {
        var store = try Store.init(allocator, .{ .max_pool_bytes = 4096 }, 1, 1);
        const pool = try store.addPool(try testMemfd(4096, true), 4096);
        try store.destroyPoolResource(pool);
        store.deinit(allocator);
    }
}

test "scoped access prevents unpin without blocking unrelated pins" {
    for ([_]bool{ true, false }) |sealed| {
        var store = try Store.init(std.testing.allocator, .{ .max_pool_bytes = 8192 }, 2, 2);
        defer store.deinit(std.testing.allocator);
        const pool = try store.addPool(try testMemfd(8192, sealed), 4096);
        const buffer = try store.addBuffer(pool, .{ .value = 0, .bytes_per_pixel = 4 }, 0, 1, 1, 4);
        const pin_value = try store.pin(buffer);
        const sibling = try store.pin(buffer);
        var outer = try store.access(pin_value);
        var nested = try store.writeAccess(pin_value);
        try store.resize(pool, 8192);
        const before = try store.poolInfo(pool);
        try std.testing.expectError(error.AccessActive, store.unpin(pin_value));
        try std.testing.expectEqualDeep(before, try store.poolInfo(pool));
        try std.testing.expectEqual(@as(usize, 2), store.active_pins);
        try store.unpin(sibling);
        try nested.end();
        try std.testing.expectError(error.StalePin, nested.end());
        try std.testing.expectError(error.AccessActive, store.unpin(pin_value));
        try outer.end();
        try store.unpin(pin_value);
        try std.testing.expectEqual(@as(usize, 8192), (try store.poolInfo(pool)).mapped_size);
        try std.testing.expectError(error.StalePin, store.unpin(pin_value));

        // A retained scope also prevents reclamation after protocol resources die.
        const retained = try store.pin(buffer);
        var scope = try store.access(retained);
        try store.destroyBuffer(buffer);
        try store.destroyPoolResource(pool);
        try std.testing.expectError(error.AccessActive, store.unpin(retained));
        try scope.end();
        try store.unpin(retained);
        try std.testing.expectEqual(@as(usize, 0), store.active_pools);
        try std.testing.expectEqual(@as(usize, 0), access_depth);
        try std.testing.expectEqual(@as(usize, 0), active_pool_address.load(.acquire));
    }
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

test "failed deferred growth remains retryable without retaining the last pin" {
    const Retry = enum { same_size, larger_size, pin_after_destroy };
    for ([_]Retry{ .same_size, .larger_size, .pin_after_destroy }) |retry| {
        var store = try Store.init(
            std.testing.allocator,
            .{ .max_pool_bytes = 12288 },
            1,
            1,
        );
        defer store.deinit(std.testing.allocator);
        const pool = try store.addPool(try testMemfd(12288, true), 4096);
        defer store.destroyPoolResource(pool) catch {};
        const buffer = try store.addBuffer(
            pool,
            .{ .value = 0, .bytes_per_pixel = 4 },
            0,
            1,
            1,
            4,
        );
        defer store.destroyBuffer(buffer) catch {};

        const original_limit = try std.posix.getrlimit(.AS);
        var limit_lowered = false;
        defer if (limit_lowered) std.posix.setrlimit(.AS, original_limit) catch unreachable;

        const first_pin = try store.pin(buffer);
        try store.resize(pool, 8192);
        try std.testing.expectError(error.ResizePending, store.pin(buffer));
        try std.posix.setrlimit(.AS, .{ .cur = 1, .max = original_limit.max });
        limit_lowered = true;
        const failure = store.unpin(first_pin);
        try std.posix.setrlimit(.AS, original_limit);
        limit_lowered = false;

        try std.testing.expectError(error.OutOfMemory, failure);
        try std.testing.expectError(error.StalePin, store.unpin(first_pin));
        var info = try store.poolInfo(pool);
        try std.testing.expectEqual(@as(usize, 0), info.pin_count);
        try std.testing.expectEqual(@as(usize, 4096), info.mapped_size);
        try std.testing.expectEqual(@as(?usize, 8192), info.pending_size);

        switch (retry) {
            .same_size => try store.resize(pool, 8192),
            .larger_size => try store.resize(pool, 12288),
            .pin_after_destroy => try store.destroyPoolResource(pool),
        }
        const retry_pin = try store.pin(buffer);
        defer store.unpin(retry_pin) catch unreachable;
        info = try store.poolInfo(pool);
        try std.testing.expectEqual(@as(usize, if (retry == .larger_size) 12288 else 8192), info.mapped_size);
        try std.testing.expectEqual(info.declared_size, info.mapped_size);
        try std.testing.expectEqual(@as(?usize, null), info.pending_size);
        try std.testing.expectEqual(retry != .pin_after_destroy, info.resource_alive);
    }
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

test "writable access mutates sealed and guarded mappings without leaking ownership" {
    var store = try Store.init(
        std.testing.allocator,
        .{ .max_pool_bytes = 4096 },
        2,
        2,
    );
    defer store.deinit(std.testing.allocator);
    const format: Format = .{ .value = 0, .bytes_per_pixel = 4 };

    const sealed_pool = try store.addPool(try testMemfd(4096, true), 4096);
    const sealed_buffer = try store.addBuffer(sealed_pool, format, 0, 1, 1, 4);
    const sealed_pin = try store.pin(sealed_buffer);
    var sealed_write = try store.writeAccess(sealed_pin);
    sealed_write.bytes[0..4].* = .{ 1, 2, 3, 4 };
    try sealed_write.end();
    var sealed_read = try store.access(sealed_pin);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, sealed_read.bytes);
    try sealed_read.end();

    const guarded_pool = try store.addPool(try testMemfd(4096, false), 4096);
    const guarded_buffer = try store.addBuffer(guarded_pool, format, 0, 1, 1, 4);
    const guarded_pin = try store.pin(guarded_buffer);
    var guarded_write = try store.writeAccess(guarded_pin);
    guarded_write.bytes[0..4].* = .{ 5, 6, 7, 8 };
    var nested_read = try store.access(guarded_pin);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, nested_read.bytes);
    try nested_read.end();
    try guarded_write.end();

    try std.testing.expectEqual(@as(usize, 0), access_depth);
    try std.testing.expectEqual(@as(usize, 0), active_pool_address.load(.acquire));
    try std.testing.expect(!backing_faulted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), store.active_pins);
    try std.testing.expectEqual(@as(usize, 1), (try store.poolInfo(sealed_pool)).pin_count);
    try std.testing.expectEqual(@as(usize, 1), (try store.poolInfo(guarded_pool)).pin_count);

    try store.unpin(guarded_pin);
    try std.testing.expectError(error.StalePin, store.writeAccess(guarded_pin));
    try std.testing.expectEqual(@as(usize, 1), store.active_pins);
    try std.testing.expectEqual(@as(usize, 0), (try store.poolInfo(guarded_pool)).pin_count);
    try store.unpin(sealed_pin);
    try std.testing.expectEqual(@as(usize, 0), store.active_pins);

    try store.destroyBuffer(guarded_buffer);
    try store.destroyPoolResource(guarded_pool);
    try store.destroyBuffer(sealed_buffer);
    try store.destroyPoolResource(sealed_pool);
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

    var truncated = try store.writeAccess(pin_value);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, 0)));
    const first: *volatile u8 = @ptrCast(truncated.bytes.ptr);
    first.* = 9;
    try std.testing.expectEqual(@as(u8, 9), first.*);
    try std.testing.expectError(error.InvalidBacking, truncated.end());
    try std.testing.expectError(error.InvalidBacking, store.access(pin_value));
    try std.testing.expectError(error.InvalidBacking, store.writeAccess(pin_value));
    try std.testing.expectEqual(@as(usize, 0), access_depth);
    try std.testing.expectEqual(@as(usize, 0), active_pool_address.load(.acquire));

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

/// Exhaustive model check of one pool's lifetime. An independent abstract
/// model predicts every Store outcome; each explored transition is replayed on
/// a real Store with real memfds, failed remaps, and SIGBUS truncation, then
/// torn down to prove the pool is always reclaimed.
const PoolModelCheck = struct {
    const sizes = [_]usize{ 4096, 8192, 12288 };
    const max_buffers = 2;
    const max_pins = 2;
    const format: Format = .{ .value = 0, .bytes_per_pixel = 4 };

    const Op = struct {
        kind: Kind,
        index: u1 = 0,
        /// Lower RLIMIT_AS so a remap attempted by this operation fails.
        fail: bool = false,

        const Kind = enum {
            destroy_resource,
            grow,
            resize_same,
            add_buffer,
            destroy_buffer,
            pin,
            unpin,
            begin_access,
            end_access,
            truncate,
            seal_restore,
        };
    };

    const ops = blk: {
        var list: []const Op = &.{
            .{ .kind = .destroy_resource },
            .{ .kind = .grow },
            .{ .kind = .grow, .fail = true },
            .{ .kind = .resize_same },
            .{ .kind = .resize_same, .fail = true },
            .{ .kind = .add_buffer },
            .{ .kind = .seal_restore },
        };
        for (0..2) |index| list = list ++ &[_]Op{
            .{ .kind = .destroy_buffer, .index = index },
            .{ .kind = .pin, .index = index },
            .{ .kind = .pin, .index = index, .fail = true },
            .{ .kind = .unpin, .index = index },
            .{ .kind = .unpin, .index = index, .fail = true },
            .{ .kind = .begin_access, .index = index },
            .{ .kind = .end_access, .index = index },
            .{ .kind = .truncate, .index = index },
        };
        break :blk list;
    };

    /// The abstract pool. Buffer and pin sizes are indexes into `sizes` for
    /// the declared pool size when the buffer was created; a buffer ends there.
    const Model = struct {
        /// The file starts shrink-sealed; otherwise it can be sealed later.
        sealed: bool,
        sealed_file: bool,
        /// File length still covers the largest pool size.
        file_full: bool = true,
        /// The store's sealed_direct, recomputed only when the mapping remaps.
        direct: bool,
        live: bool = true,
        resource: bool = true,
        declared: u2 = 0,
        mapped: u2 = 0,
        faulted: bool = false,
        invalid: bool = false,
        buffer_len: u2 = 0,
        buffer_size: [max_buffers]u2 = @splat(0),
        pin_len: u2 = 0,
        pin_size: [max_pins]u2 = @splat(0),
        pin_access: [max_pins]bool = @splat(false),

        fn pending(model: Model) bool {
            return model.declared != model.mapped;
        }

        fn openAccesses(model: Model) usize {
            var count: usize = 0;
            for (model.pin_access[0..model.pin_len]) |open| count += @intFromBool(open);
            return count;
        }

        fn remapped(model: *Model, size: u2) void {
            model.mapped = size;
            model.direct = model.sealed_file and model.file_full;
        }

        fn release(model: *Model) void {
            if (model.live and !model.resource and model.buffer_len == 0 and model.pin_len == 0)
                model.live = false;
        }

        /// Canonical encoding; buffers and pins are unordered multisets.
        fn key(model: Model) u32 {
            var buffers: [max_buffers]u32 = @splat(0);
            for (model.buffer_size[0..model.buffer_len], 0..) |size, index| buffers[index] = size;
            std.mem.sort(u32, buffers[0..model.buffer_len], {}, std.sort.asc(u32));
            var pins: [max_pins]u32 = @splat(0);
            for (0..model.pin_len) |index|
                pins[index] = @as(u32, model.pin_size[index]) << 1 | @intFromBool(model.pin_access[index]);
            std.mem.sort(u32, pins[0..model.pin_len], {}, std.sort.asc(u32));
            var value: u32 = @intFromBool(model.live);
            value = value << 1 | @intFromBool(model.resource);
            value = value << 2 | model.declared;
            value = value << 2 | model.mapped;
            value = value << 1 | @intFromBool(model.faulted);
            value = value << 1 | @intFromBool(model.invalid);
            value = value << 1 | @intFromBool(model.sealed_file);
            value = value << 1 | @intFromBool(model.file_full);
            value = value << 1 | @intFromBool(model.direct);
            value = value << 2 | model.buffer_len;
            for (buffers) |size| value = value << 2 | size;
            value = value << 2 | model.pin_len;
            for (pins) |pin_key| value = value << 3 | pin_key;
            return value;
        }
    };

    const World = struct {
        store: Store,
        fd: linux.fd_t,
        pool: PoolToken,
        model: Model,
        buffers: [max_buffers]BufferToken = undefined,
        pins: [max_pins]Store.Pin = undefined,
        accesses: [max_pins]?Store.WriteAccess = @splat(null),

        /// Initializes in place: active accesses point at `store`.
        fn init(world: *World, sealed: bool) !void {
            world.* = .{
                .store = try Store.init(
                    std.testing.allocator,
                    .{ .max_pool_bytes = sizes[sizes.len - 1] },
                    1,
                    max_buffers,
                ),
                .fd = undefined,
                .pool = undefined,
                .model = .{ .sealed = sealed, .sealed_file = sealed, .direct = sealed },
            };
            errdefer world.store.deinit(std.testing.allocator);
            world.fd = if (sealed) try testMemfd(sizes[sizes.len - 1], true) else blk: {
                // Sealable but unsealed, so `seal_restore` can seal it later.
                const result = linux.memfd_create(
                    "wayring-shm-model",
                    linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING,
                );
                try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
                const fd: linux.fd_t = @intCast(result);
                errdefer _ = linux.close(fd);
                try std.testing.expectEqual(
                    linux.E.SUCCESS,
                    linux.errno(linux.ftruncate(fd, sizes[sizes.len - 1])),
                );
                break :blk fd;
            };
            world.pool = try world.store.addPool(world.fd, sizes[0]);
        }

        fn lowerAddressSpace(fail: bool) !?linux.rlimit {
            if (!fail) return null;
            const original = try std.posix.getrlimit(.AS);
            try std.posix.setrlimit(.AS, .{ .cur = 1, .max = original.max });
            return original;
        }

        fn restoreAddressSpace(original: ?linux.rlimit) void {
            if (original) |limit| std.posix.setrlimit(.AS, limit) catch unreachable;
        }

        /// Applies `op` to both the model and the real store, checking that
        /// the store's outcome matches the model. Returns false when `op` is
        /// not applicable in this state.
        fn apply(world: *World, op: Op) !bool {
            const model = &world.model;
            const store = &world.store;
            const index = op.index;
            switch (op.kind) {
                .destroy_resource => {
                    if (!model.live) {
                        try std.testing.expectError(error.StalePool, store.destroyPoolResource(world.pool));
                    } else if (!model.resource) {
                        try std.testing.expectError(error.ResourceDestroyed, store.destroyPoolResource(world.pool));
                    } else {
                        try store.destroyPoolResource(world.pool);
                        model.resource = false;
                        model.release();
                    }
                },
                .grow, .resize_same => {
                    if (!model.live or !model.resource) {
                        if (op.fail or op.kind == .resize_same) return false;
                        const expected: StoreError = if (model.live) error.ResourceDestroyed else error.StalePool;
                        try std.testing.expectError(expected, store.resize(world.pool, @intCast(sizes[1])));
                        return true;
                    }
                    const target: u2 = if (op.kind == .grow) blk: {
                        if (model.declared == sizes.len - 1) return false;
                        break :blk model.declared + 1;
                    } else model.declared;
                    const remaps = model.pin_len == 0 and (target != model.mapped);
                    if (op.fail and !remaps) return false;
                    const limit = try lowerAddressSpace(op.fail);
                    const result = store.resize(world.pool, @intCast(sizes[target]));
                    restoreAddressSpace(limit);
                    if (op.fail) {
                        try std.testing.expectError(error.OutOfMemory, result);
                    } else {
                        try result;
                        model.declared = target;
                        if (remaps) model.remapped(target);
                    }
                },
                .add_buffer => {
                    if (!model.live) return false;
                    if (!model.resource) {
                        try std.testing.expectError(
                            error.ResourceDestroyed,
                            store.addBuffer(world.pool, format, 0, 1, 1, 4),
                        );
                        return true;
                    }
                    if (model.buffer_len == max_buffers) return false;
                    // The buffer ends exactly at the declared size, which may
                    // exceed the mapping while growth is deferred.
                    const offset: i32 = @intCast(sizes[model.declared] - 4);
                    world.buffers[model.buffer_len] = try store.addBuffer(world.pool, format, offset, 1, 1, 4);
                    model.buffer_size[model.buffer_len] = model.declared;
                    model.buffer_len += 1;
                },
                .destroy_buffer => {
                    if (index >= model.buffer_len) return false;
                    try store.destroyBuffer(world.buffers[index]);
                    for (index..model.buffer_len - 1) |slot| {
                        world.buffers[slot] = world.buffers[slot + 1];
                        model.buffer_size[slot] = model.buffer_size[slot + 1];
                    }
                    model.buffer_len -= 1;
                    model.release();
                },
                .pin => {
                    if (index >= model.buffer_len or model.pin_len == max_pins) return false;
                    const blocked = model.pending() and model.pin_len != 0;
                    const remaps = model.pending() and model.pin_len == 0;
                    if (op.fail and !remaps) return false;
                    const limit = try lowerAddressSpace(op.fail);
                    const result = store.pin(world.buffers[index]);
                    restoreAddressSpace(limit);
                    if (blocked) {
                        try std.testing.expectError(error.ResizePending, result);
                    } else if (op.fail) {
                        try std.testing.expectError(error.OutOfMemory, result);
                    } else {
                        world.pins[model.pin_len] = try result;
                        world.accesses[model.pin_len] = null;
                        model.pin_size[model.pin_len] = model.buffer_size[index];
                        model.pin_access[model.pin_len] = false;
                        model.pin_len += 1;
                        if (remaps) model.remapped(model.declared);
                    }
                },
                .unpin => {
                    if (index >= model.pin_len) return false;
                    const accessed = model.pin_access[index];
                    const remaps = !accessed and model.pin_len == 1 and model.pending();
                    if (op.fail and !remaps) return false;
                    const limit = try lowerAddressSpace(op.fail);
                    const result = store.unpin(world.pins[index]);
                    restoreAddressSpace(limit);
                    if (accessed) {
                        try std.testing.expectError(error.AccessActive, result);
                        return true;
                    }
                    // The pin is consumed even when deferred growth fails.
                    if (op.fail) try std.testing.expectError(error.OutOfMemory, result) else try result;
                    for (index..model.pin_len - 1) |slot| {
                        world.pins[slot] = world.pins[slot + 1];
                        world.accesses[slot] = world.accesses[slot + 1];
                        model.pin_size[slot] = model.pin_size[slot + 1];
                        model.pin_access[slot] = model.pin_access[slot + 1];
                    }
                    model.pin_len -= 1;
                    world.accesses[model.pin_len] = null;
                    model.pin_access[model.pin_len] = false;
                    if (remaps and !op.fail) model.remapped(model.declared);
                    model.release();
                },
                .begin_access => {
                    if (index >= model.pin_len or model.pin_access[index]) return false;
                    if (model.invalid) {
                        try std.testing.expectError(error.InvalidBacking, store.writeAccess(world.pins[index]));
                        return true;
                    }
                    world.accesses[index] = try store.writeAccess(world.pins[index]);
                    model.pin_access[index] = true;
                },
                .end_access => {
                    if (index >= model.pin_len or !model.pin_access[index]) return false;
                    const outermost = model.openAccesses() == 1;
                    const result = world.accesses[index].?.end();
                    world.accesses[index] = null;
                    model.pin_access[index] = false;
                    if (model.faulted and outermost) {
                        try std.testing.expectError(error.InvalidBacking, result);
                        model.faulted = false;
                        model.invalid = true;
                    } else try result;
                },
                .truncate => {
                    if (model.sealed_file or model.faulted or model.invalid) return false;
                    if (index >= model.pin_len or !model.pin_access[index]) return false;
                    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(world.fd, 0)));
                    const target: *volatile u8 = @ptrCast(world.accesses[index].?.bytes.ptr);
                    target.* = 1;
                    model.faulted = true;
                    model.file_full = false;
                },
                .seal_restore => {
                    // A client restores the file length and shrink-seals it.
                    if (model.sealed_file or !model.live) return false;
                    try std.testing.expectEqual(
                        linux.E.SUCCESS,
                        linux.errno(linux.ftruncate(world.fd, sizes[sizes.len - 1])),
                    );
                    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(
                        world.fd,
                        linux.F.ADD_SEALS,
                        linux.F.SEAL_SHRINK,
                    )));
                    model.sealed_file = true;
                    model.file_full = true;
                },
            }
            return true;
        }

        /// Compares real store state with the model and checks memory-safety
        /// invariants: pinned and accessed ranges always lie inside the mapping.
        fn check(world: *World) !void {
            const model = world.model;
            if (!model.live) {
                try std.testing.expectError(error.StalePool, world.store.poolInfo(world.pool));
                try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(world.fd, linux.F.GETFD, 0)));
                try std.testing.expectEqual(@as(usize, 0), world.store.active_pools);
                return;
            }
            const info = try world.store.poolInfo(world.pool);
            try std.testing.expectEqual(sizes[model.mapped], info.mapped_size);
            try std.testing.expectEqual(sizes[model.declared], info.declared_size);
            try std.testing.expectEqual(
                if (model.pending()) @as(?usize, sizes[model.declared]) else null,
                info.pending_size,
            );
            try std.testing.expectEqual(@as(usize, model.buffer_len), info.buffer_count);
            try std.testing.expectEqual(@as(usize, model.pin_len), info.pin_count);
            try std.testing.expectEqual(model.resource, info.resource_alive);
            try std.testing.expectEqual(model.direct, info.sealed_direct);

            const pool = try world.store.resolvePool(world.pool);
            try std.testing.expectEqual(model.invalid, pool.invalid_backing);
            const start = @intFromPtr(pool.mapping.ptr);
            for (world.pins[0..model.pin_len], world.accesses[0..model.pin_len], 0..) |pin_value, maybe_access, slot| {
                const pin_node = try world.store.resolvePin(pin_value.token);
                try std.testing.expect(pin_node.metadata.end() <= pool.mapping.len);
                try std.testing.expectEqual(sizes[model.pin_size[slot]], pin_node.metadata.end());
                if (model.invalid) {
                    try std.testing.expectError(error.InvalidBacking, world.store.bytes(pin_value));
                } else if (model.direct) {
                    const view = try world.store.bytes(pin_value);
                    try std.testing.expect(@intFromPtr(view.ptr) + view.len <= start + pool.mapping.len);
                } else try std.testing.expectError(error.UnsafeAccess, world.store.bytes(pin_value));
                if (maybe_access) |scope| {
                    try std.testing.expect(@intFromPtr(scope.bytes.ptr) >= start);
                    try std.testing.expect(@intFromPtr(scope.bytes.ptr) + scope.bytes.len <= start + pool.mapping.len);
                }
            }
            const guarded_open = if (model.direct) 0 else model.openAccesses();
            try std.testing.expectEqual(guarded_open, access_depth);
            try std.testing.expectEqual(
                if (guarded_open != 0) @intFromPtr(pool) else 0,
                active_pool_address.load(.acquire),
            );
        }

        /// Liveness: ordinary teardown from any state reclaims the pool,
        /// closes its descriptor, and leaves no guarded access behind.
        fn teardown(world: *World) !void {
            for (0..max_pins) |slot| {
                if (slot < world.model.pin_len and world.model.pin_access[slot])
                    try std.testing.expect(try world.apply(.{ .kind = .end_access, .index = @intCast(slot) }));
            }
            while (world.model.pin_len != 0) try std.testing.expect(try world.apply(.{ .kind = .unpin }));
            while (world.model.buffer_len != 0) try std.testing.expect(try world.apply(.{ .kind = .destroy_buffer }));
            if (world.model.live) try std.testing.expect(try world.apply(.{ .kind = .destroy_resource }));
            try std.testing.expect(!world.model.live);
            try world.check();
            try std.testing.expectEqual(@as(usize, 0), access_depth);
            world.store.deinit(std.testing.allocator);
        }
    };

    const Node = struct { parent: u32, op: Op };

    /// Breadth-first exploration of abstract states; returns the state count.
    fn explore(sealed: bool) !usize {
        const allocator = std.testing.allocator;
        var nodes: std.ArrayList(Node) = .empty;
        defer nodes.deinit(allocator);
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(allocator);

        var root: World = undefined;
        try root.init(sealed);
        try root.check();
        try seen.put(allocator, root.model.key(), {});
        try root.teardown();
        try nodes.append(allocator, .{ .parent = std.math.maxInt(u32), .op = undefined });

        var path: [64]Op = undefined;
        var current: usize = 0;
        while (current < nodes.items.len) : (current += 1) {
            var depth: usize = 0;
            var cursor: u32 = @intCast(current);
            while (cursor != 0) : (cursor = nodes.items[cursor].parent) {
                path[path.len - 1 - depth] = nodes.items[cursor].op;
                depth += 1;
            }
            // Inapplicable operations leave the world untouched, so one replay
            // serves every operation until one applies.
            var world: World = undefined;
            var replayed = false;
            for (ops) |op| {
                if (!replayed) {
                    try world.init(sealed);
                    for (path[path.len - depth ..]) |step| try std.testing.expect(try world.apply(step));
                    replayed = true;
                }
                if (!try world.apply(op)) continue;
                replayed = false;
                try world.check();
                const key = world.model.key();
                try world.teardown();
                if (seen.contains(key)) continue;
                try seen.put(allocator, key, {});
                try nodes.append(allocator, .{ .parent = @intCast(current), .op = op });
            }
            if (replayed) try world.teardown();
        }
        return nodes.items.len;
    }
};

test "SHM pool lifetime matches an exhaustive model and always reclaims" {
    const sealed_states = try PoolModelCheck.explore(true);
    const guarded_states = try PoolModelCheck.explore(false);
    // Guarded pools add truncation faults and invalid backing states.
    try std.testing.expect(sealed_states > 100);
    try std.testing.expect(guarded_states > sealed_states);
}
