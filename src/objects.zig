//! Bounded object-ID lookup with no steady-state allocation.

const std = @import("std");
const metadata = @import("metadata.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    CapacityOverflow,
    InvalidId,
    DuplicateId,
    Full,
};

pub const Handle = struct {
    id: u32,
    generation: u32,
};

pub const Object = struct {
    interface: *const metadata.Interface,
    version: u32,
    context: ?*anyopaque = null,
};

/// Cold-path notification for published objects removed individually or by
/// connection teardown. Transactional cancellation does not invoke this hook.
pub const RemovalHook = struct {
    context: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, Handle, Object) void,
};

pub const Dispatch = struct {
    object: *Object,
    message: metadata.Message,

    /// Copies callback-visible metadata when the callback may remove its source
    /// object. The hot path can otherwise use the table entry in place.
    pub inline fn snapshot(dispatch: Dispatch) Object {
        return dispatch.object.*;
    }
};

pub const NamespaceError = Error || metadata.Error || error{UnknownObject};

/// A policy-light object namespace suitable for a single Wayland connection.
/// It validates interface versions at insertion and message availability at
/// lookup, leaving typed decoding and handler representation to the runtime.
pub const Namespace = struct {
    table: Table(Object),

    pub fn init(
        allocator: std.mem.Allocator,
        max_objects: usize,
    ) NamespaceError!Namespace {
        return .{ .table = try Table(Object).init(allocator, max_objects) };
    }

    pub fn deinit(namespace: *Namespace, allocator: std.mem.Allocator) void {
        namespace.table.deinit(allocator);
        namespace.* = undefined;
    }

    pub fn iterator(namespace: *Namespace) Table(Object).Iterator {
        return namespace.table.iterator();
    }

    pub fn insert(
        namespace: *Namespace,
        id: u32,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) NamespaceError!Handle {
        try interface.validateVersion(version);
        return namespace.table.insert(id, .{
            .interface = interface,
            .version = version,
            .context = context,
        });
    }

    pub fn request(
        namespace: *Namespace,
        id: u32,
        opcode: u16,
    ) NamespaceError!Dispatch {
        const object = namespace.table.get(id) orelse return error.UnknownObject;
        return .{
            .object = object,
            .message = try object.interface.request(opcode, object.version),
        };
    }

    pub fn event(
        namespace: *Namespace,
        id: u32,
        opcode: u16,
    ) NamespaceError!Dispatch {
        const object = namespace.table.get(id) orelse return error.UnknownObject;
        return .{
            .object = object,
            .message = try object.interface.event(opcode, object.version),
        };
    }

    pub fn remove(namespace: *Namespace, handle: Handle) ?Object {
        return namespace.table.removeHandle(handle);
    }

    pub fn get(namespace: *Namespace, id: u32) ?*Object {
        return namespace.table.get(id);
    }

    pub fn resolve(namespace: *Namespace, handle: Handle) ?*Object {
        return namespace.table.resolve(handle);
    }

    pub fn lookupHandle(namespace: *Namespace, id: u32) ?Handle {
        return namespace.table.lookupHandle(id);
    }
};

pub const server_id_start: u32 = 0xff00_0000;
pub const display_id: u32 = 1;

pub const ClientIdError = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    InvalidId,
    InvalidTransition,
};

/// Tracks the reuse protocol for IDs created by a Wayland client. Storage is
/// allocated once; an ID retired locally is not reusable until delete_id is
/// received from the server.
pub const ClientIds = struct {
    const never_used = std.math.maxInt(u32);
    const active = never_used - 1;
    const awaiting_delete = never_used - 2;
    const no_free_id = never_used - 3;

    /// Each active slot contains a state sentinel. Each free slot contains the
    /// index of the next free slot, making the free list intrusive.
    entries: []u32,
    next_index: usize = 0,
    free_head: u32 = no_free_id,

    pub fn init(allocator: std.mem.Allocator, max_ids: usize) ClientIdError!ClientIds {
        const id_space = @as(usize, server_id_start) - 2;
        if (max_ids == 0 or max_ids > id_space) return error.InvalidConfig;
        const entries = try allocator.alloc(u32, max_ids);
        @memset(entries, never_used);
        return .{ .entries = entries };
    }

    pub fn deinit(ids: *ClientIds, allocator: std.mem.Allocator) void {
        allocator.free(ids.entries);
        ids.* = undefined;
    }

    pub fn acquire(ids: *ClientIds) ClientIdError!u32 {
        if (ids.free_head != no_free_id) {
            const index = ids.free_head;
            ids.free_head = ids.entries[index];
            ids.entries[index] = active;
            return index + 2;
        }
        if (ids.next_index == ids.entries.len) return error.Exhausted;
        const index = ids.next_index;
        ids.next_index += 1;
        ids.entries[index] = active;
        return @intCast(index + 2);
    }

    /// Marks an ID whose destructor request has been published. Its object may
    /// be removed from dispatch immediately, but the numeric ID remains held.
    pub fn retire(ids: *ClientIds, id: u32) ClientIdError!void {
        const index = ids.usedIndex(id) orelse return error.InvalidId;
        if (ids.entries[index] != active) return error.InvalidTransition;
        ids.entries[index] = awaiting_delete;
    }

    /// Applies wl_display.delete_id and makes a retired ID reusable.
    pub fn deleted(ids: *ClientIds, id: u32) ClientIdError!void {
        const index = ids.usedIndex(id) orelse return error.InvalidId;
        if (ids.entries[index] != awaiting_delete) return error.InvalidTransition;
        ids.releaseIndex(index);
    }

    /// Rolls back an ID that was allocated but never exposed on the wire.
    pub fn cancelUnpublished(ids: *ClientIds, id: u32) ClientIdError!void {
        const index = ids.usedIndex(id) orelse return error.InvalidId;
        if (ids.entries[index] != active) return error.InvalidTransition;
        ids.releaseIndex(index);
    }

    pub fn isActive(ids: ClientIds, id: u32) bool {
        const index = ids.usedIndex(id) orelse return false;
        return ids.entries[index] == active;
    }

    fn usedIndex(ids: ClientIds, id: u32) ?usize {
        const index = indexOf(id) orelse return null;
        if (index >= ids.next_index) return null;
        return index;
    }

    fn indexOf(id: u32) ?usize {
        if (id < 2 or id >= server_id_start) return null;
        return @as(usize, id) - 2;
    }

    fn releaseIndex(ids: *ClientIds, index: usize) void {
        ids.entries[index] = ids.free_head;
        ids.free_head = @intCast(index);
    }
};

pub const ClientObjectsError = NamespaceError || ClientIdError || error{
    InvalidLocalId,
    InvalidPeerId,
    StaleHandle,
};

/// Couples client-created ID reuse rules to the dispatch namespace while
/// preserving transactional rollback when a creation request is not queued.
pub const ClientObjects = struct {
    namespace: Namespace,
    ids: ClientIds,

    pub fn init(
        allocator: std.mem.Allocator,
        max_objects: usize,
        max_client_ids: usize,
        display_interface: *const metadata.Interface,
        display_context: ?*anyopaque,
    ) ClientObjectsError!ClientObjects {
        var namespace = try Namespace.init(allocator, max_objects);
        errdefer namespace.deinit(allocator);
        var ids = try ClientIds.init(allocator, max_client_ids);
        errdefer ids.deinit(allocator);
        _ = try namespace.insert(
            display_id,
            display_interface,
            1,
            display_context,
        );
        return .{ .namespace = namespace, .ids = ids };
    }

    pub fn deinit(objects: *ClientObjects, allocator: std.mem.Allocator) void {
        objects.ids.deinit(allocator);
        objects.namespace.deinit(allocator);
        objects.* = undefined;
    }

    pub fn iterator(objects: *ClientObjects) Table(Object).Iterator {
        return objects.namespace.iterator();
    }

    pub fn createLocal(
        objects: *ClientObjects,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) ClientObjectsError!Handle {
        const id = try objects.ids.acquire();
        errdefer objects.ids.cancelUnpublished(id) catch unreachable;
        return objects.namespace.insert(id, interface, version, context);
    }

    /// Removes a local object whose creation request failed before publication.
    pub fn cancelLocal(objects: *ClientObjects, handle: Handle) ClientObjectsError!Object {
        if (handle.id < 2 or handle.id >= server_id_start) return error.InvalidLocalId;
        const value = objects.namespace.resolve(handle) orelse return error.StaleHandle;
        _ = value;
        try objects.ids.cancelUnpublished(handle.id);
        return objects.namespace.remove(handle).?;
    }

    /// Removes a locally destroyed object from dispatch but keeps its ID held
    /// until `deleted` applies wl_display.delete_id.
    pub fn retireLocal(objects: *ClientObjects, handle: Handle) ClientObjectsError!Object {
        if (handle.id < 2 or handle.id >= server_id_start) return error.InvalidLocalId;
        const value = objects.namespace.resolve(handle) orelse return error.StaleHandle;
        _ = value;
        try objects.ids.retire(handle.id);
        return objects.namespace.remove(handle).?;
    }

    pub fn deleted(objects: *ClientObjects, id: u32) ClientObjectsError!void {
        try objects.ids.deleted(id);
    }

    pub fn insertPeer(
        objects: *ClientObjects,
        id: u32,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) ClientObjectsError!Handle {
        if (id < server_id_start) return error.InvalidPeerId;
        return objects.namespace.insert(id, interface, version, context);
    }

    pub fn removePeer(objects: *ClientObjects, handle: Handle) ClientObjectsError!Object {
        if (handle.id < server_id_start) return error.InvalidPeerId;
        return objects.namespace.remove(handle) orelse error.StaleHandle;
    }
};

pub const ServerIdError = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    InvalidId,
    InvalidTransition,
};

/// Dense allocator for IDs created by a server in Wayland's reserved high
/// range. Released IDs are reused through an intrusive O(1) free list.
pub const ServerIds = struct {
    const never_used = std.math.maxInt(u32);
    const active = never_used - 1;
    const no_free_id = never_used - 2;

    entries: []u32,
    next_index: usize = 0,
    free_head: u32 = no_free_id,

    pub fn init(allocator: std.mem.Allocator, max_ids: usize) ServerIdError!ServerIds {
        const id_space = @as(usize, std.math.maxInt(u32)) - server_id_start + 1;
        if (max_ids == 0 or max_ids > id_space) return error.InvalidConfig;
        const entries = try allocator.alloc(u32, max_ids);
        @memset(entries, never_used);
        return .{ .entries = entries };
    }

    pub fn deinit(ids: *ServerIds, allocator: std.mem.Allocator) void {
        allocator.free(ids.entries);
        ids.* = undefined;
    }

    pub fn acquire(ids: *ServerIds) ServerIdError!u32 {
        if (ids.free_head != no_free_id) {
            const index = ids.free_head;
            ids.free_head = ids.entries[index];
            ids.entries[index] = active;
            return server_id_start + index;
        }
        if (ids.next_index == ids.entries.len) return error.Exhausted;
        const index = ids.next_index;
        ids.next_index += 1;
        ids.entries[index] = active;
        return server_id_start + @as(u32, @intCast(index));
    }

    pub fn release(ids: *ServerIds, id: u32) ServerIdError!void {
        const index = ids.usedIndex(id) orelse return error.InvalidId;
        if (ids.entries[index] != active) return error.InvalidTransition;
        ids.entries[index] = ids.free_head;
        ids.free_head = @intCast(index);
    }

    fn usedIndex(ids: ServerIds, id: u32) ?usize {
        if (id < server_id_start) return null;
        const index = @as(usize, id - server_id_start);
        if (index >= ids.next_index) return null;
        return index;
    }
};

pub const ServerObjectsError = NamespaceError || ServerIdError || error{
    InvalidClientId,
    InvalidServerId,
    StaleHandle,
};

/// Object ownership rules for one server-side client connection.
pub const ServerObjects = struct {
    namespace: Namespace,
    ids: ServerIds,
    removal_hook: ?RemovalHook = null,

    pub fn init(
        allocator: std.mem.Allocator,
        max_objects: usize,
        max_server_ids: usize,
        display_interface: *const metadata.Interface,
        display_context: ?*anyopaque,
    ) ServerObjectsError!ServerObjects {
        var namespace = try Namespace.init(allocator, max_objects);
        errdefer namespace.deinit(allocator);
        var ids = try ServerIds.init(allocator, max_server_ids);
        errdefer ids.deinit(allocator);
        _ = try namespace.insert(
            display_id,
            display_interface,
            1,
            display_context,
        );
        return .{ .namespace = namespace, .ids = ids };
    }

    pub fn deinit(server_objects: *ServerObjects, allocator: std.mem.Allocator) void {
        if (server_objects.removal_hook) |hook| {
            var entries = server_objects.iterator();
            while (entries.next()) |entry| hook.notify(
                hook.context,
                entry.handle,
                entry.value.*,
            );
        }
        server_objects.ids.deinit(allocator);
        server_objects.namespace.deinit(allocator);
        server_objects.* = undefined;
    }

    pub fn iterator(server_objects: *ServerObjects) Table(Object).Iterator {
        return server_objects.namespace.iterator();
    }

    pub fn setRemovalHook(server_objects: *ServerObjects, hook: ?RemovalHook) void {
        server_objects.removal_hook = hook;
    }

    pub fn insertClient(
        server_objects: *ServerObjects,
        id: u32,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) ServerObjectsError!Handle {
        if (id < 2 or id >= server_id_start) return error.InvalidClientId;
        return server_objects.namespace.insert(id, interface, version, context);
    }

    pub fn removeClient(
        server_objects: *ServerObjects,
        handle: Handle,
    ) ServerObjectsError!Object {
        const object = try server_objects.cancelClient(handle);
        if (server_objects.removal_hook) |hook| hook.notify(hook.context, handle, object);
        return object;
    }

    pub fn cancelClient(
        server_objects: *ServerObjects,
        handle: Handle,
    ) ServerObjectsError!Object {
        if (handle.id < 2 or handle.id >= server_id_start) return error.InvalidClientId;
        return server_objects.namespace.remove(handle) orelse error.StaleHandle;
    }

    pub fn createLocal(
        server_objects: *ServerObjects,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) ServerObjectsError!Handle {
        const id = try server_objects.ids.acquire();
        errdefer server_objects.ids.release(id) catch unreachable;
        return server_objects.namespace.insert(id, interface, version, context);
    }

    pub fn removeLocal(
        server_objects: *ServerObjects,
        handle: Handle,
    ) ServerObjectsError!Object {
        if (handle.id < server_id_start) return error.InvalidServerId;
        if (server_objects.namespace.resolve(handle) == null)
            return error.StaleHandle;
        try server_objects.ids.release(handle.id);
        const object = server_objects.namespace.remove(handle).?;
        if (server_objects.removal_hook) |hook| hook.notify(hook.context, handle, object);
        return object;
    }
};

const shared_end = std.math.maxInt(u32);

pub const SharedObjectBucket = struct {
    connection_generation: u32 = 0,
    head: u32 = shared_end,
};

const SharedObjectNode = struct {
    object: Object = undefined,
    id: u32 = 0,
    generation: u32 = 0,
    bucket_next: u32 = shared_end,
    owner_previous: u32 = shared_end,
    owner_next: u32 = shared_end,
};

/// Physical object entries shared by every server-side connection on a
/// reactor. Per-connection namespaces enforce logical quotas independently.
pub const SharedObjectPool = struct {
    nodes: []SharedObjectNode,
    free_head: u32,
    available_count: usize,
    reserved_count: usize = 0,
    next_generation: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!SharedObjectPool {
        const server_id_space = @as(usize, std.math.maxInt(u32)) - server_id_start + 1;
        if (capacity == 0 or capacity > server_id_space) return error.InvalidConfig;
        const nodes = try allocator.alloc(SharedObjectNode, capacity);
        for (nodes, 0..) |*node, index| {
            node.owner_next = if (index + 1 < nodes.len)
                @intCast(index + 1)
            else
                shared_end;
        }
        return .{
            .nodes = nodes,
            .free_head = 0,
            .available_count = capacity,
        };
    }

    pub fn deinit(pool: *SharedObjectPool, allocator: std.mem.Allocator) void {
        std.debug.assert(pool.available_count == pool.nodes.len);
        allocator.free(pool.nodes);
        pool.* = undefined;
    }

    pub fn available(pool: SharedObjectPool) usize {
        return pool.available_count;
    }

    pub fn reserve(pool: *SharedObjectPool, count: usize) Error!void {
        if (count > pool.available_count - pool.reserved_count) return error.Full;
        pool.reserved_count += count;
    }

    pub fn restoreReservation(pool: *SharedObjectPool) void {
        std.debug.assert(pool.reserved_count < pool.available_count);
        pool.reserved_count += 1;
    }

    fn acquire(pool: *SharedObjectPool) Error!u32 {
        if (pool.available_count == pool.reserved_count) return error.Full;
        return pool.acquirePhysical();
    }

    fn acquireReserved(pool: *SharedObjectPool) Error!u32 {
        if (pool.reserved_count == 0) return error.Full;
        pool.reserved_count -= 1;
        return pool.acquirePhysical() catch |err| {
            pool.reserved_count += 1;
            return err;
        };
    }

    fn acquirePhysical(pool: *SharedObjectPool) Error!u32 {
        if (pool.free_head == shared_end) return error.Full;
        const index = pool.free_head;
        pool.free_head = pool.nodes[index].owner_next;
        pool.available_count -= 1;
        return index;
    }

    fn release(pool: *SharedObjectPool, index: u32) void {
        pool.nodes[index].owner_next = pool.free_head;
        pool.free_head = index;
        pool.available_count += 1;
    }

    fn releaseChain(pool: *SharedObjectPool, head: u32, tail: u32, count: usize) void {
        if (head == shared_end) return;
        pool.nodes[tail].owner_next = pool.free_head;
        pool.free_head = head;
        pool.available_count += count;
    }

    fn takeGeneration(pool: *SharedObjectPool) u32 {
        const generation = pool.next_generation;
        pool.next_generation +%= 1;
        if (pool.next_generation == 0) pool.next_generation = 1;
        return generation;
    }
};

/// A connection-scoped view over a shared object pool. Bucket stamps avoid
/// clearing per-slot metadata when a reactor slot is reused, while an intrusive
/// ownership chain makes whole-client teardown O(1).
pub const SharedNamespace = struct {
    pub const Entry = struct {
        handle: Handle,
        value: *Object,
    };

    pub const Iterator = struct {
        namespace: *SharedNamespace,
        current: u32,

        pub fn next(self: *Iterator) ?Entry {
            if (self.current == shared_end) return null;
            const node = &self.namespace.pool.nodes[self.current];
            self.current = node.owner_next;
            return .{
                .handle = .{ .id = node.id, .generation = node.generation },
                .value = &node.object,
            };
        }
    };

    pool: *SharedObjectPool,
    buckets: []SharedObjectBucket,
    connection_generation: u32,
    quota: usize,
    count: usize = 0,
    owner_head: u32 = shared_end,
    owner_tail: u32 = shared_end,
    cached_id: u32 = 0,
    cached_index: u32 = shared_end,

    pub fn init(
        pool: *SharedObjectPool,
        buckets: []SharedObjectBucket,
        connection_generation: u32,
        quota: usize,
    ) Error!SharedNamespace {
        if (buckets.len < 2 or !std.math.isPowerOfTwo(buckets.len) or
            connection_generation == 0 or quota == 0 or quota > pool.nodes.len)
            return error.InvalidConfig;
        return .{
            .pool = pool,
            .buckets = buckets,
            .connection_generation = connection_generation,
            .quota = quota,
        };
    }

    pub fn deinit(namespace: *SharedNamespace) void {
        namespace.pool.releaseChain(
            namespace.owner_head,
            namespace.owner_tail,
            namespace.count,
        );
        namespace.* = undefined;
    }

    pub fn len(namespace: SharedNamespace) usize {
        return namespace.count;
    }

    /// Iteration follows the connection's intrusive ownership chain without
    /// allocation. The namespace must not be mutated while an iterator is live.
    pub fn iterator(namespace: *SharedNamespace) Iterator {
        return .{ .namespace = namespace, .current = namespace.owner_head };
    }

    pub fn insert(
        namespace: *SharedNamespace,
        id: u32,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) NamespaceError!Handle {
        if (id == 0) return error.InvalidId;
        try interface.validateVersion(version);
        if (namespace.find(id) != null) return error.DuplicateId;
        if (namespace.count == namespace.quota) return error.Full;
        const index = try namespace.pool.acquire();
        return namespace.insertAcquired(index, id, interface, version, context);
    }

    pub fn insertServer(
        namespace: *SharedNamespace,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) NamespaceError!Handle {
        try interface.validateVersion(version);
        if (namespace.count == namespace.quota) return error.Full;
        const index = try namespace.pool.acquire();
        const id = server_id_start + index;
        std.debug.assert(namespace.find(id) == null);
        return namespace.insertAcquired(index, id, interface, version, context);
    }

    pub fn insertReserved(
        namespace: *SharedNamespace,
        id: u32,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) NamespaceError!Handle {
        if (id == 0) return error.InvalidId;
        try interface.validateVersion(version);
        if (namespace.find(id) != null) return error.DuplicateId;
        if (namespace.count == namespace.quota) return error.Full;
        const index = try namespace.pool.acquireReserved();
        return namespace.insertAcquired(index, id, interface, version, context);
    }

    pub fn request(
        namespace: *SharedNamespace,
        id: u32,
        opcode: u16,
    ) NamespaceError!Dispatch {
        const object = namespace.get(id) orelse return error.UnknownObject;
        return .{
            .object = object,
            .message = try object.interface.request(opcode, object.version),
        };
    }

    pub fn event(
        namespace: *SharedNamespace,
        id: u32,
        opcode: u16,
    ) NamespaceError!Dispatch {
        const object = namespace.get(id) orelse return error.UnknownObject;
        return .{
            .object = object,
            .message = try object.interface.event(opcode, object.version),
        };
    }

    pub fn get(namespace: *SharedNamespace, id: u32) ?*Object {
        const location = namespace.find(id) orelse return null;
        return &namespace.pool.nodes[location.index].object;
    }

    pub fn resolve(namespace: *SharedNamespace, handle: Handle) ?*Object {
        const location = namespace.find(handle.id) orelse return null;
        const node = &namespace.pool.nodes[location.index];
        if (node.generation != handle.generation) return null;
        return &node.object;
    }

    pub fn lookupHandle(namespace: *SharedNamespace, id: u32) ?Handle {
        const location = namespace.find(id) orelse return null;
        const node = &namespace.pool.nodes[location.index];
        return .{ .id = id, .generation = node.generation };
    }

    pub fn remove(namespace: *SharedNamespace, handle: Handle) ?Object {
        const location = namespace.findUncached(handle.id) orelse return null;
        const node = &namespace.pool.nodes[location.index];
        if (node.generation != handle.generation) return null;
        const object = node.object;
        if (namespace.cached_index == location.index) {
            namespace.cached_id = 0;
            namespace.cached_index = shared_end;
        }

        if (location.previous == shared_end)
            namespace.activeBucket(handle.id).head = node.bucket_next
        else
            namespace.pool.nodes[location.previous].bucket_next = node.bucket_next;
        if (node.owner_previous == shared_end)
            namespace.owner_head = node.owner_next
        else
            namespace.pool.nodes[node.owner_previous].owner_next = node.owner_next;
        if (node.owner_next == shared_end)
            namespace.owner_tail = node.owner_previous
        else
            namespace.pool.nodes[node.owner_next].owner_previous = node.owner_previous;
        namespace.count -= 1;
        namespace.pool.release(location.index);
        return object;
    }

    const Location = struct {
        index: u32,
        previous: u32,
    };

    fn find(namespace: *SharedNamespace, id: u32) ?Location {
        if (id == 0) return null;
        if (namespace.cached_id == id) return .{
            .index = namespace.cached_index,
            .previous = shared_end,
        };
        const location = namespace.findUncached(id) orelse return null;
        namespace.cached_id = id;
        namespace.cached_index = location.index;
        return location;
    }

    fn findUncached(namespace: *SharedNamespace, id: u32) ?Location {
        if (id == 0) return null;
        const bucket = &namespace.buckets[namespace.home(id)];
        if (bucket.connection_generation != namespace.connection_generation)
            return null;
        var previous: u32 = shared_end;
        var current = bucket.head;
        while (current != shared_end) {
            const node = &namespace.pool.nodes[current];
            if (node.id == id) return .{ .index = current, .previous = previous };
            previous = current;
            current = node.bucket_next;
        }
        return null;
    }

    fn insertAcquired(
        namespace: *SharedNamespace,
        index: u32,
        id: u32,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) Handle {
        const bucket = namespace.activeBucket(id);
        const generation = namespace.pool.takeGeneration();
        namespace.pool.nodes[index] = .{
            .object = .{
                .interface = interface,
                .version = version,
                .context = context,
            },
            .id = id,
            .generation = generation,
            .bucket_next = bucket.head,
            .owner_previous = namespace.owner_tail,
            .owner_next = shared_end,
        };
        bucket.head = index;
        if (namespace.owner_tail == shared_end)
            namespace.owner_head = index
        else
            namespace.pool.nodes[namespace.owner_tail].owner_next = index;
        namespace.owner_tail = index;
        namespace.count += 1;
        return .{ .id = id, .generation = generation };
    }

    fn activeBucket(namespace: *SharedNamespace, id: u32) *SharedObjectBucket {
        const bucket = &namespace.buckets[namespace.home(id)];
        if (bucket.connection_generation != namespace.connection_generation) {
            bucket.connection_generation = namespace.connection_generation;
            bucket.head = shared_end;
        }
        return bucket;
    }

    fn home(namespace: SharedNamespace, id: u32) usize {
        const mixed = @as(u64, id) *% 0x9e3779b97f4a7c15;
        const bits = std.math.log2_int(usize, namespace.buckets.len);
        const shift: u6 = @intCast(63 - (bits - 1));
        return @intCast(mixed >> shift);
    }
};

/// Server-side object policy over reactor-wide shared physical entries.
pub const SharedServerObjects = struct {
    namespace: SharedNamespace,
    removal_hook: ?RemovalHook = null,

    pub fn init(
        pool: *SharedObjectPool,
        buckets: []SharedObjectBucket,
        connection_generation: u32,
        quota: usize,
        display_interface: *const metadata.Interface,
        display_context: ?*anyopaque,
    ) ServerObjectsError!SharedServerObjects {
        return initInternal(
            pool,
            buckets,
            connection_generation,
            quota,
            display_interface,
            display_context,
            false,
        );
    }

    pub fn initReserved(
        pool: *SharedObjectPool,
        buckets: []SharedObjectBucket,
        connection_generation: u32,
        quota: usize,
        display_interface: *const metadata.Interface,
        display_context: ?*anyopaque,
    ) ServerObjectsError!SharedServerObjects {
        return initInternal(
            pool,
            buckets,
            connection_generation,
            quota,
            display_interface,
            display_context,
            true,
        );
    }

    fn initInternal(
        pool: *SharedObjectPool,
        buckets: []SharedObjectBucket,
        connection_generation: u32,
        quota: usize,
        display_interface: *const metadata.Interface,
        display_context: ?*anyopaque,
        reserved: bool,
    ) ServerObjectsError!SharedServerObjects {
        var namespace = try SharedNamespace.init(
            pool,
            buckets,
            connection_generation,
            quota,
        );
        errdefer namespace.deinit();
        _ = if (reserved)
            try namespace.insertReserved(
                display_id,
                display_interface,
                1,
                display_context,
            )
        else
            try namespace.insert(
                display_id,
                display_interface,
                1,
                display_context,
            );
        return .{ .namespace = namespace };
    }

    pub fn deinit(server_objects: *SharedServerObjects) void {
        if (server_objects.removal_hook) |hook| {
            var entries = server_objects.iterator();
            while (entries.next()) |entry| hook.notify(
                hook.context,
                entry.handle,
                entry.value.*,
            );
        }
        server_objects.namespace.deinit();
        server_objects.* = undefined;
    }

    pub fn iterator(server_objects: *SharedServerObjects) SharedNamespace.Iterator {
        return server_objects.namespace.iterator();
    }

    pub fn setRemovalHook(server_objects: *SharedServerObjects, hook: ?RemovalHook) void {
        server_objects.removal_hook = hook;
    }

    pub fn insertClient(
        server_objects: *SharedServerObjects,
        id: u32,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) ServerObjectsError!Handle {
        if (id < 2 or id >= server_id_start) return error.InvalidClientId;
        return server_objects.namespace.insert(id, interface, version, context);
    }

    pub fn removeClient(
        server_objects: *SharedServerObjects,
        handle: Handle,
    ) ServerObjectsError!Object {
        const object = try server_objects.cancelClient(handle);
        if (server_objects.removal_hook) |hook| hook.notify(hook.context, handle, object);
        return object;
    }

    pub fn cancelClient(
        server_objects: *SharedServerObjects,
        handle: Handle,
    ) ServerObjectsError!Object {
        if (handle.id < 2 or handle.id >= server_id_start) return error.InvalidClientId;
        return server_objects.namespace.remove(handle) orelse error.StaleHandle;
    }

    pub fn createLocal(
        server_objects: *SharedServerObjects,
        interface: *const metadata.Interface,
        version: u32,
        context: ?*anyopaque,
    ) ServerObjectsError!Handle {
        return server_objects.namespace.insertServer(interface, version, context);
    }

    pub fn removeLocal(
        server_objects: *SharedServerObjects,
        handle: Handle,
    ) ServerObjectsError!Object {
        if (handle.id < server_id_start) return error.InvalidServerId;
        const object = server_objects.namespace.remove(handle) orelse return error.StaleHandle;
        if (server_objects.removal_hook) |hook| hook.notify(hook.context, handle, object);
        return object;
    }
};

/// Fixed-capacity open-addressed storage. Values and IDs may be chosen by the
/// runtime using it; this layer deliberately does not prescribe client/server
/// allocation policy or dispatch representation.
pub fn Table(comptime Value: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            id: u32,
            generation: u32,
            value: Value,
        };

        pub const Entry = struct {
            handle: Handle,
            value: *Value,
        };

        pub const Iterator = struct {
            table: *Self,
            index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.table.slots.len) {
                    const index = self.index;
                    self.index += 1;
                    const slot = &self.table.slots[index];
                    if (slot.id != 0) return .{
                        .handle = .{ .id = slot.id, .generation = slot.generation },
                        .value = &slot.value,
                    };
                }
                return null;
            }
        };

        slots: []Slot,
        max_entries: usize,
        count: usize = 0,
        next_generation: u32 = 1,

        pub fn init(
            allocator: std.mem.Allocator,
            max_entries: usize,
        ) Error!Self {
            if (max_entries == 0 or max_entries > std.math.maxInt(u32))
                return error.InvalidConfig;
            const scaled = std.math.mul(usize, max_entries, 4) catch
                return error.CapacityOverflow;
            const minimum_slots = std.math.divCeil(usize, scaled, 3) catch unreachable;
            const slot_count = std.math.ceilPowerOfTwo(
                usize,
                @max(minimum_slots, 2),
            ) catch return error.CapacityOverflow;
            const slots = try allocator.alloc(Slot, slot_count);
            for (slots) |*slot| slot.id = 0;
            return .{
                .slots = slots,
                .max_entries = max_entries,
            };
        }

        pub fn deinit(table: *Self, allocator: std.mem.Allocator) void {
            allocator.free(table.slots);
            table.* = undefined;
        }

        pub fn len(table: Self) usize {
            return table.count;
        }

        pub fn capacity(table: Self) usize {
            return table.max_entries;
        }

        /// The table must not be mutated while an iterator is live.
        pub fn iterator(table: *Self) Iterator {
            return .{ .table = table };
        }

        /// Returned pointers remain valid until the next insertion or removal.
        pub fn get(table: *Self, id: u32) ?*Value {
            const index = table.find(id) orelse return null;
            return &table.slots[index].value;
        }

        pub fn getConst(table: *const Self, id: u32) ?*const Value {
            const index = table.find(id) orelse return null;
            return &table.slots[index].value;
        }

        pub fn resolve(table: *Self, handle: Handle) ?*Value {
            const index = table.find(handle.id) orelse return null;
            const slot = &table.slots[index];
            if (slot.generation != handle.generation) return null;
            return &slot.value;
        }

        pub fn lookupHandle(table: *const Self, id: u32) ?Handle {
            const index = table.find(id) orelse return null;
            return .{ .id = id, .generation = table.slots[index].generation };
        }

        pub fn insert(table: *Self, id: u32, value: Value) Error!Handle {
            if (id == 0) return error.InvalidId;

            var index = table.home(id);
            while (table.slots[index].id != 0) {
                if (table.slots[index].id == id) return error.DuplicateId;
                index = table.next(index);
            }
            if (table.count == table.max_entries) return error.Full;
            const generation = table.takeGeneration();
            table.slots[index] = .{
                .id = id,
                .generation = generation,
                .value = value,
            };
            table.count += 1;
            return .{ .id = id, .generation = generation };
        }

        /// Removes an ID and transfers its value to the caller.
        pub fn remove(table: *Self, id: u32) ?Value {
            const removed_index = table.find(id) orelse return null;
            const value = table.slots[removed_index].value;
            table.closeHole(removed_index);
            table.count -= 1;
            return value;
        }

        pub fn removeHandle(table: *Self, handle: Handle) ?Value {
            const index = table.find(handle.id) orelse return null;
            if (table.slots[index].generation != handle.generation) return null;
            const value = table.slots[index].value;
            table.closeHole(index);
            table.count -= 1;
            return value;
        }

        fn find(table: *const Self, id: u32) ?usize {
            if (id == 0) return null;
            var index = table.home(id);
            for (0..table.slots.len) |_| {
                const existing = table.slots[index].id;
                if (existing == 0) return null;
                if (existing == id) return index;
                index = table.next(index);
            }
            return null;
        }

        fn closeHole(table: *Self, initial_hole: usize) void {
            var hole = initial_hole;
            var scan = table.next(hole);
            while (table.slots[scan].id != 0) {
                const home_index = table.home(table.slots[scan].id);
                if (probeDistance(table.slots.len, home_index, scan) >
                    probeDistance(table.slots.len, home_index, hole))
                {
                    table.slots[hole] = table.slots[scan];
                    hole = scan;
                }
                scan = table.next(scan);
            }
            table.slots[hole].id = 0;
        }

        fn home(table: Self, id: u32) usize {
            const mixed = @as(u64, id) *% 0x9e3779b97f4a7c15;
            const bits = std.math.log2_int(usize, table.slots.len);
            const shift: u6 = @intCast(63 - (bits - 1));
            return @intCast(mixed >> shift);
        }

        fn next(table: Self, index: usize) usize {
            return (index + 1) & (table.slots.len - 1);
        }

        fn takeGeneration(table: *Self) u32 {
            const generation = table.next_generation;
            table.next_generation +%= 1;
            if (table.next_generation == 0) table.next_generation = 1;
            return generation;
        }
    };
}

fn probeDistance(capacity: usize, home: usize, index: usize) usize {
    return (index -% home) & (capacity - 1);
}

test "inserts, looks up, removes, and enforces its logical capacity" {
    const SampleObject = struct { version: u32 };
    var table = try Table(SampleObject).init(std.testing.allocator, 2);
    defer table.deinit(std.testing.allocator);

    const first = try table.insert(7, .{ .version = 3 });
    _ = try table.insert(9, .{ .version = 1 });
    try std.testing.expectEqual(@as(usize, 2), table.len());
    try std.testing.expectEqual(@as(u32, 3), table.resolve(first).?.version);
    try std.testing.expectError(error.DuplicateId, table.insert(7, .{ .version = 4 }));
    try std.testing.expectError(error.Full, table.insert(11, .{ .version = 1 }));
    try std.testing.expectEqual(@as(u32, 3), table.remove(7).?.version);
    try std.testing.expectEqual(@as(?*SampleObject, null), table.get(7));
}

test "backshift deletion preserves colliding lookups including wraparound" {
    var table = try Table(u32).init(std.testing.allocator, 4);
    defer table.deinit(std.testing.allocator);

    var colliding: [3]u32 = undefined;
    var found: usize = 0;
    var id: u32 = 1;
    const target_home = table.slots.len - 1;
    while (found < colliding.len) : (id += 1) {
        if (table.home(id) == target_home) {
            colliding[found] = id;
            found += 1;
        }
    }
    for (colliding) |value| _ = try table.insert(value, value);
    try std.testing.expectEqual(colliding[0], table.remove(colliding[0]).?);
    try std.testing.expectEqual(colliding[1], table.get(colliding[1]).?.*);
    try std.testing.expectEqual(colliding[2], table.get(colliding[2]).?.*);
}

test "backshift scans past an entry in its home slot" {
    var table = try Table(u32).init(std.testing.allocator, 4);
    defer table.deinit(std.testing.allocator);

    var first: u32 = 1;
    while (table.home(first) != 0) : (first += 1) {}
    var interposed: u32 = 1;
    while (table.home(interposed) != 1) : (interposed += 1) {}
    var trailing = first + 1;
    while (table.home(trailing) != 0) : (trailing += 1) {}

    _ = try table.insert(first, first);
    _ = try table.insert(interposed, interposed);
    _ = try table.insert(trailing, trailing);
    _ = table.remove(first);
    try std.testing.expectEqual(trailing, table.get(trailing).?.*);
}

test "generation rejects stale handles after an ID is reused" {
    var table = try Table(u8).init(std.testing.allocator, 1);
    defer table.deinit(std.testing.allocator);

    const stale = try table.insert(4, 1);
    try std.testing.expectEqual(@as(u8, 1), table.removeHandle(stale).?);
    const current = try table.insert(4, 2);
    try std.testing.expect(stale.generation != current.generation);
    try std.testing.expectEqual(@as(?*u8, null), table.resolve(stale));
    try std.testing.expectEqual(@as(u8, 2), table.resolve(current).?.*);
}

test "iterator visits each occupied slot" {
    var table = try Table(u32).init(std.testing.allocator, 4);
    defer table.deinit(std.testing.allocator);
    _ = try table.insert(2, 20);
    _ = try table.insert(7, 70);

    var total: u32 = 0;
    var iterator = table.iterator();
    while (iterator.next()) |entry| total += entry.value.*;
    try std.testing.expectEqual(@as(u32, 90), total);
}

test "rejects zero IDs and releases allocation failures" {
    var table = try Table(void).init(std.testing.allocator, 1);
    defer table.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidId, table.insert(0, {}));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initAndDeinit,
        .{@as(usize, 128)},
    );
}

test "client IDs wait for delete_id before reuse" {
    var ids = try ClientIds.init(std.testing.allocator, 2);
    defer ids.deinit(std.testing.allocator);

    const first = try ids.acquire();
    const second = try ids.acquire();
    try std.testing.expectEqual(@as(u32, 2), first);
    try std.testing.expectEqual(@as(u32, 3), second);
    try ids.retire(first);
    try std.testing.expectError(error.Exhausted, ids.acquire());
    try ids.deleted(first);
    try std.testing.expectEqual(first, try ids.acquire());
    try std.testing.expect(ids.isActive(first));
}

test "client ID transitions reject premature and duplicate reuse" {
    var ids = try ClientIds.init(std.testing.allocator, 2);
    defer ids.deinit(std.testing.allocator);

    const id = try ids.acquire();
    try std.testing.expectError(error.InvalidTransition, ids.deleted(id));
    try ids.cancelUnpublished(id);
    try std.testing.expectError(error.InvalidTransition, ids.cancelUnpublished(id));
    try std.testing.expectEqual(id, try ids.acquire());
    try std.testing.expectError(error.InvalidId, ids.retire(server_id_start));
}

test "client ID allocator releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initClientIdsAndDeinit,
        .{@as(usize, 128)},
    );
}

test "namespace validates object and message versions before dispatch" {
    const info: metadata.Interface = .{
        .name = "sample_v2",
        .version = 2,
        .requests = &.{
            .{ .since = 1 },
            .{ .since = 2, .destructor = true },
        },
        .events = &.{.{ .since = 1 }},
    };
    var namespace = try Namespace.init(std.testing.allocator, 2);
    defer namespace.deinit(std.testing.allocator);

    const handle = try namespace.insert(7, &info, 1, null);
    const prepared = try namespace.request(7, 0);
    try std.testing.expect(!prepared.message.destructor);
    try std.testing.expectError(error.UnsupportedVersion, namespace.request(7, 1));
    try std.testing.expectError(error.UnknownObject, namespace.event(8, 0));
    try std.testing.expectError(
        error.InvalidObjectVersion,
        namespace.insert(9, &info, 3, null),
    );
    const snapshot = prepared.snapshot();
    try std.testing.expect(namespace.remove(handle) != null);
    try std.testing.expectEqual(&info, snapshot.interface);
    try std.testing.expectEqual(@as(u32, 1), snapshot.version);
}

test "client objects transact creation, retirement, and peer IDs" {
    const display_info: metadata.Interface = .{
        .name = "wl_display",
        .version = 1,
        .requests = &.{},
        .events = &.{},
    };
    const child_info: metadata.Interface = .{
        .name = "child_v1",
        .version = 2,
        .requests = &.{},
        .events = &.{},
    };
    var objects = try ClientObjects.init(
        std.testing.allocator,
        4,
        2,
        &display_info,
        null,
    );
    defer objects.deinit(std.testing.allocator);

    const unpublished = try objects.createLocal(&child_info, 1, null);
    _ = try objects.cancelLocal(unpublished);
    const first = try objects.createLocal(&child_info, 2, null);
    try std.testing.expectEqual(unpublished.id, first.id);
    _ = try objects.retireLocal(first);
    const second = try objects.createLocal(&child_info, 1, null);
    try std.testing.expect(first.id != second.id);
    try std.testing.expectError(error.Exhausted, objects.createLocal(&child_info, 1, null));
    try objects.deleted(first.id);
    const reused = try objects.createLocal(&child_info, 1, null);
    try std.testing.expectEqual(first.id, reused.id);

    const peer = try objects.insertPeer(server_id_start, &child_info, 1, null);
    _ = try objects.removePeer(peer);
    try std.testing.expectError(
        error.InvalidPeerId,
        objects.insertPeer(10, &child_info, 1, null),
    );
}

test "server objects separate client and server ID ownership" {
    const display_info: metadata.Interface = .{
        .name = "wl_display",
        .version = 1,
        .requests = &.{},
        .events = &.{},
    };
    const child_info: metadata.Interface = .{
        .name = "child_v1",
        .version = 1,
        .requests = &.{},
        .events = &.{},
    };
    var server_objects = try ServerObjects.init(
        std.testing.allocator,
        4,
        2,
        &display_info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var removal_count: usize = 0;
    server_objects.setRemovalHook(.{
        .context = &removal_count,
        .notify = countRemoval,
    });

    const client = try server_objects.insertClient(7, &child_info, 1, null);
    try std.testing.expectError(
        error.InvalidClientId,
        server_objects.insertClient(server_id_start, &child_info, 1, null),
    );
    _ = try server_objects.removeClient(client);
    try std.testing.expectEqual(@as(usize, 1), removal_count);
    const unpublished = try server_objects.insertClient(8, &child_info, 1, null);
    _ = try server_objects.cancelClient(unpublished);
    try std.testing.expectEqual(@as(usize, 1), removal_count);

    const first = try server_objects.createLocal(&child_info, 1, null);
    try std.testing.expectEqual(server_id_start, first.id);
    _ = try server_objects.removeLocal(first);
    try std.testing.expectEqual(@as(usize, 2), removal_count);
    const reused = try server_objects.createLocal(&child_info, 1, null);
    try std.testing.expectEqual(first.id, reused.id);
}

fn countRemoval(context: ?*anyopaque, _: Handle, _: Object) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

test "server namespaces share physical objects with isolated quotas" {
    const display_info: metadata.Interface = .{
        .name = "wl_display",
        .version = 1,
        .requests = &.{.{ .since = 1 }},
        .events = &.{},
    };
    const child_info: metadata.Interface = .{
        .name = "child_v1",
        .version = 1,
        .requests = &.{},
        .events = &.{},
    };
    var pool = try SharedObjectPool.init(std.testing.allocator, 5);
    defer pool.deinit(std.testing.allocator);
    var first_buckets = [_]SharedObjectBucket{.{}} ** 4;
    var second_buckets = [_]SharedObjectBucket{.{}} ** 4;
    var first = try SharedServerObjects.init(
        &pool,
        &first_buckets,
        1,
        2,
        &display_info,
        null,
    );
    var first_live = true;
    defer if (first_live) first.deinit();
    var second = try SharedServerObjects.init(
        &pool,
        &second_buckets,
        7,
        3,
        &display_info,
        null,
    );
    defer second.deinit();

    const first_child = try first.insertClient(2, &child_info, 1, null);
    try std.testing.expectError(
        error.Full,
        first.insertClient(3, &child_info, 1, null),
    );
    const second_child = try second.insertClient(2, &child_info, 1, null);
    try std.testing.expect(first.namespace.resolve(first_child) != null);
    try std.testing.expect(second.namespace.resolve(second_child) != null);
    try std.testing.expectEqual(@as(usize, 1), pool.available());

    var first_objects = first.iterator();
    const display_entry = first_objects.next().?;
    try std.testing.expectEqual(display_id, display_entry.handle.id);
    try std.testing.expectEqual(&display_info, display_entry.value.interface);
    const child_entry = first_objects.next().?;
    try std.testing.expectEqual(first_child, child_entry.handle);
    try std.testing.expectEqual(&child_info, child_entry.value.interface);
    try std.testing.expectEqual(null, first_objects.next());

    first.deinit();
    first_live = false;
    try std.testing.expectEqual(@as(usize, 3), pool.available());
    var reused = try SharedServerObjects.init(
        &pool,
        &first_buckets,
        2,
        2,
        &display_info,
        null,
    );
    defer reused.deinit();
    try std.testing.expect(reused.namespace.resolve(first_child) == null);
    try std.testing.expectError(error.UnknownObject, reused.namespace.request(2, 0));

    const local = try reused.createLocal(&child_info, 1, null);
    try std.testing.expect(local.id >= server_id_start);
    _ = try reused.removeLocal(local);

    const colliding = try second.insertClient(5, &child_info, 1, null);
    try std.testing.expect(second.namespace.resolve(second_child) != null);
    _ = try second.removeClient(second_child);
    try std.testing.expect(second.namespace.resolve(colliding) != null);
}

fn initAndDeinit(allocator: std.mem.Allocator, capacity: usize) !void {
    var table = try Table(usize).init(allocator, capacity);
    table.deinit(allocator);
}

fn initClientIdsAndDeinit(allocator: std.mem.Allocator, capacity: usize) !void {
    var ids = try ClientIds.init(allocator, capacity);
    ids.deinit(allocator);
}
