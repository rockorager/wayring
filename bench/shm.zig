const std = @import("std");
const wayring = @import("wayring");

const linux = std.os.linux;

const Mode = enum { sealed, copy, guarded, nested };

const Options = struct {
    mode: Mode = .copy,
    size: usize = 64 * 1024,
    operations: usize = 16 * 1024,
    batch: usize = 16,
    warmup: usize = 1024,
};

const Context = struct {
    allocator: std.mem.Allocator,
    store: wayring.shm.Store,
    pool: wayring.shm.PoolToken,
    buffer: wayring.shm.BufferToken,
    ring: linux.IoUring,
    destinations: []u8,
    copies: []wayring.shm.Store.Copy,
    pins: []wayring.shm.Store.Pin,
    size: usize,
    batch: usize,

    fn init(allocator: std.mem.Allocator, options: Options) !Context {
        const sealed = options.mode == .sealed;
        const flags: u32 = linux.MFD.CLOEXEC |
            if (sealed) @as(u32, linux.MFD.ALLOW_SEALING) else 0;
        const fd_result = linux.memfd_create("wayring-shm-benchmark", flags);
        if (linux.errno(fd_result) != .SUCCESS) return error.SystemCallFailed;
        const fd: linux.fd_t = @intCast(fd_result);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(options.size))) != .SUCCESS)
            return error.SystemCallFailed;
        const marker = [_]u8{0xa5};
        if (linux.write(fd, &marker, marker.len) != marker.len)
            return error.SystemCallFailed;
        if (sealed and linux.errno(linux.fcntl(
            fd,
            linux.F.ADD_SEALS,
            linux.F.SEAL_SHRINK,
        )) != .SUCCESS) return error.SystemCallFailed;

        var store = try wayring.shm.Store.init(
            allocator,
            .{ .max_pool_bytes = options.size },
            1,
            options.batch,
        );
        errdefer store.deinit(allocator);
        const pool = try store.addPool(fd, @intCast(options.size));
        errdefer store.destroyPoolResource(pool) catch unreachable;
        const buffer = try store.addBuffer(
            pool,
            .{ .value = 0, .bytes_per_pixel = 1 },
            0,
            @intCast(options.size),
            1,
            @intCast(options.size),
        );
        errdefer store.destroyBuffer(buffer) catch unreachable;

        var entries: u16 = 1;
        while (entries < options.batch) entries *= 2;
        var ring = try linux.IoUring.init(entries, 0);
        errdefer ring.deinit();
        const destination_bytes = if (options.mode == .copy)
            std.math.mul(usize, options.size, options.batch) catch
                return error.InvalidOptions
        else
            0;
        const destinations = try allocator.alloc(u8, destination_bytes);
        errdefer allocator.free(destinations);
        const copies = try allocator.alloc(
            wayring.shm.Store.Copy,
            if (options.mode == .copy) options.batch else 0,
        );
        errdefer allocator.free(copies);
        const pins = try allocator.alloc(wayring.shm.Store.Pin, options.batch);
        return .{
            .allocator = allocator,
            .store = store,
            .pool = pool,
            .buffer = buffer,
            .ring = ring,
            .destinations = destinations,
            .copies = copies,
            .pins = pins,
            .size = options.size,
            .batch = options.batch,
        };
    }

    fn deinit(context: *Context) void {
        context.allocator.free(context.pins);
        context.allocator.free(context.copies);
        context.allocator.free(context.destinations);
        context.ring.deinit();
        context.store.destroyBuffer(context.buffer) catch unreachable;
        context.store.destroyPoolResource(context.pool) catch unreachable;
        context.store.deinit(context.allocator);
        context.* = undefined;
    }

    fn runSealed(context: *Context, operations: usize) !u64 {
        var completed: usize = 0;
        var checksum: u64 = 0;
        while (completed < operations) {
            const count = @min(context.batch, operations - completed);
            for (0..count) |index| {
                context.pins[index] = try context.store.pin(context.buffer);
                const bytes = try context.store.bytes(context.pins[index]);
                const first: *const volatile u8 = @ptrCast(&bytes[0]);
                const last: *const volatile u8 = @ptrCast(&bytes[bytes.len - 1]);
                checksum +%= first.*;
                checksum +%= last.*;
            }
            for (0..count) |index| try context.store.unpin(context.pins[index]);
            completed += count;
        }
        return checksum;
    }

    fn runGuarded(context: *Context, operations: usize, nested: bool) !u64 {
        const pin = try context.store.pin(context.buffer);
        defer context.store.unpin(pin) catch unreachable;
        var outer = if (nested) try context.store.access(pin) else null;
        defer if (outer) |*scope| scope.end() catch unreachable;
        var checksum: u64 = 0;
        for (0..operations) |_| {
            var scope = try context.store.access(pin);
            const first: *const volatile u8 = @ptrCast(&scope.bytes[0]);
            const last: *const volatile u8 = @ptrCast(&scope.bytes[scope.bytes.len - 1]);
            checksum +%= first.*;
            checksum +%= last.*;
            try scope.end();
        }
        return checksum;
    }

    fn runCopy(context: *Context, operations: usize) !u64 {
        var completed: usize = 0;
        var checksum: u64 = 0;
        while (completed < operations) {
            const count = @min(context.batch, operations - completed);
            for (0..count) |index| {
                const destination = context.destinations[index * context.size ..][0..context.size];
                context.copies[index] = try context.store.prepareCopy(
                    &context.ring,
                    context.buffer,
                    destination,
                    index,
                );
            }
            _ = try context.ring.submit();
            for (0..count) |_| {
                const completion = try context.ring.copy_cqe();
                const index: usize = @intCast(completion.user_data);
                if (index >= count) return error.InvalidCompletion;
                const bytes = try context.store.completeCopy(
                    context.copies[index],
                    completion,
                );
                checksum +%= bytes[0];
                checksum +%= bytes[bytes.len - 1];
            }
            completed += count;
        }
        return checksum;
    }
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    const options = try parseOptions(init.args);
    const allocator = std.heap.page_allocator;
    var context = try Context.init(allocator, options);
    defer context.deinit();
    _ = switch (options.mode) {
        .sealed => try context.runSealed(options.warmup),
        .copy => try context.runCopy(options.warmup),
        .guarded, .nested => try context.runGuarded(options.warmup, options.mode == .nested),
    };
    const start = try monotonicNs();
    const checksum = switch (options.mode) {
        .sealed => try context.runSealed(options.operations),
        .copy => try context.runCopy(options.operations),
        .guarded, .nested => try context.runGuarded(options.operations, options.mode == .nested),
    };
    const elapsed = try monotonicNs() - start;
    const total_bytes = std.math.mul(usize, options.size, options.operations) catch
        return error.InvalidOptions;
    const submissions = if (options.mode == .copy)
        (options.operations + options.batch - 1) / options.batch
    else
        0;
    var storage: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&storage, "backend=wayring-shm mode={s} size={} operations={} batch={} elapsed_ns={} ns_per_operation={d:.1} bytes_per_second={d:.0} operations_per_second={d:.0} submissions={} checksum={}\n", .{
        @tagName(options.mode),
        options.size,
        options.operations,
        options.batch,
        elapsed,
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(options.operations)),
        @as(f64, @floatFromInt(total_bytes)) * @as(f64, std.time.ns_per_s) /
            @as(f64, @floatFromInt(elapsed)),
        @as(f64, @floatFromInt(options.operations)) * @as(f64, std.time.ns_per_s) /
            @as(f64, @floatFromInt(elapsed)),
        submissions,
        checksum,
    });
    if (linux.write(1, line.ptr, line.len) != line.len) return error.SystemCallFailed;
    return 0;
}

fn parseOptions(args: std.process.Args) !Options {
    var options: Options = .{};
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.skip();
    if (iterator.next()) |value| {
        options.mode = std.meta.stringToEnum(Mode, value) orelse return error.InvalidOptions;
    }
    if (iterator.next()) |value| options.size = try std.fmt.parseUnsigned(usize, value, 10);
    if (iterator.next()) |value| options.operations = try std.fmt.parseUnsigned(usize, value, 10);
    if (iterator.next()) |value| options.batch = try std.fmt.parseUnsigned(usize, value, 10);
    if (iterator.next()) |value| options.warmup = try std.fmt.parseUnsigned(usize, value, 10);
    if (iterator.next() != null or options.size == 0 or
        options.size > std.math.maxInt(i32) or options.operations == 0 or
        options.batch == 0 or options.batch > 1024 or options.warmup == 0)
        return error.InvalidOptions;
    return options;
}

fn monotonicNs() !u64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC_RAW, &time)) != .SUCCESS)
        return error.SystemCallFailed;
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(time.nsec));
}

test "guarded access contention benchmark" {
    const operations = 100_000;
    const Worker = struct {
        context: *Context,
        ready: *std.atomic.Value(usize),
        go: *std.atomic.Value(bool),
        checksum: u64 = 0,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
            self.checksum = self.context.runGuarded(operations, false) catch unreachable;
        }
    };
    for ([_]usize{ 1, 2 }) |thread_count| {
        var samples: [5]u64 = undefined;
        for (&samples) |*sample| {
            var contexts: [2]Context = undefined;
            var initialized: usize = 0;
            defer for (contexts[0..initialized]) |*context| context.deinit();
            for (contexts[0..thread_count]) |*context| {
                context.* = try Context.init(std.heap.page_allocator, .{ .mode = .guarded, .size = 4096, .batch = 1 });
                initialized += 1;
                _ = try context.runGuarded(1000, false);
            }
            var ready: std.atomic.Value(usize) = .init(0);
            var go: std.atomic.Value(bool) = .init(false);
            var workers: [2]Worker = undefined;
            var threads: [2]std.Thread = undefined;
            var spawned: usize = 0;
            errdefer {
                go.store(true, .release);
                for (threads[0..spawned]) |thread| thread.join();
            }
            for (workers[0..thread_count], threads[0..thread_count], contexts[0..thread_count]) |*worker, *thread, *context| {
                worker.* = .{ .context = context, .ready = &ready, .go = &go };
                thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
                spawned += 1;
            }
            while (ready.load(.acquire) != thread_count) std.atomic.spinLoopHint();
            const start = try monotonicNs();
            go.store(true, .release);
            for (threads[0..spawned]) |thread| thread.join();
            spawned = 0;
            sample.* = try monotonicNs() - start;
            for (workers[0..thread_count]) |worker| try std.testing.expectEqual(@as(u64, operations * 0xa5), worker.checksum);
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.debug.print("threads={} median_aggregate_ns_per_scope={}\n", .{ thread_count, samples[2] / (operations * thread_count) });
    }
}
