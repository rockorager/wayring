//! Runtime Wayland protocol tracing compatible with `WAYLAND_DEBUG`.
//!
//! Tracing is detected once from the process's launch environment and remains
//! available in every optimization mode. The disabled hot path is one atomic
//! load and one predictable branch; formatting and system calls occur only
//! while tracing is enabled.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Side = enum(u1) {
    client,
    server,
};

const State = enum(u8) {
    unknown,
    initializing,
    disabled,
    client,
    server,
    both,
};

var state: State = .unknown;
var output_lock: std.atomic.Mutex = .unlocked;

/// Returns whether protocol tracing is enabled for `side`. Like libwayland,
/// values containing "1", "client", or "server" enable the corresponding
/// endpoint. The launch environment is inspected only on the first call.
pub inline fn enabled(side: Side) bool {
    var current = @atomicLoad(State, &state, .monotonic);
    if (current == .unknown or current == .initializing)
        current = initialize();
    return current == .both or switch (side) {
        .client => current == .client,
        .server => current == .server,
    };
}

fn initialize() State {
    if (@cmpxchgStrong(State, &state, .unknown, .initializing, .acquire, .acquire) == null) {
        const detected = detectLaunchEnvironment();
        @atomicStore(State, &state, detected, .release);
        return detected;
    }
    while (true) {
        const current = @atomicLoad(State, &state, .acquire);
        if (current != .unknown and current != .initializing) return current;
        _ = linux.sched_yield();
    }
}

fn detectLaunchEnvironment() State {
    if (builtin.link_libc) {
        const value = std.c.getenv("WAYLAND_DEBUG") orelse return .disabled;
        return parseValue(std.mem.span(value));
    }

    const result = linux.open("/proc/self/environ", .{ .CLOEXEC = true }, 0);
    if (linux.errno(result) != .SUCCESS) return .disabled;
    const fd: linux.fd_t = @intCast(result);
    defer _ = linux.close(fd);

    var parser: EnvironmentParser = .{};
    var storage: [4096]u8 = undefined;
    while (true) {
        const read_result = linux.read(fd, &storage, storage.len);
        switch (linux.errno(read_result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .disabled,
        }
        if (read_result == 0) return parser.finish();
        if (parser.consume(storage[0..read_result])) |detected| return detected;
    }
}

fn parseValue(value: []const u8) State {
    const has_one = std.mem.indexOfScalar(u8, value, '1') != null;
    const has_client = std.mem.indexOf(u8, value, "client") != null;
    const has_server = std.mem.indexOf(u8, value, "server") != null;
    if (has_one or (has_client and has_server)) return .both;
    if (has_client) return .client;
    if (has_server) return .server;
    return .disabled;
}

const EnvironmentParser = struct {
    const prefix = "WAYLAND_DEBUG=";

    prefix_index: ?usize = 0,
    target: bool = false,
    client_index: usize = 0,
    server_index: usize = 0,
    has_client: bool = false,
    has_server: bool = false,
    has_one: bool = false,

    fn consume(parser: *EnvironmentParser, bytes: []const u8) ?State {
        for (bytes) |byte| {
            if (byte == 0) {
                if (parser.target) return parser.result();
                parser.* = .{};
                continue;
            }
            if (!parser.target) {
                const index = parser.prefix_index orelse continue;
                if (byte != prefix[index]) {
                    parser.prefix_index = null;
                } else if (index + 1 == prefix.len) {
                    parser.target = true;
                    parser.prefix_index = null;
                } else {
                    parser.prefix_index = index + 1;
                }
                continue;
            }
            parser.has_one = parser.has_one or byte == '1';
            parser.has_client = parser.has_client or match(byte, "client", &parser.client_index);
            parser.has_server = parser.has_server or match(byte, "server", &parser.server_index);
        }
        return null;
    }

    fn finish(parser: EnvironmentParser) State {
        if (!parser.target) return .disabled;
        return parser.result();
    }

    fn result(parser: EnvironmentParser) State {
        if (parser.has_one or (parser.has_client and parser.has_server)) return .both;
        if (parser.has_client) return .client;
        if (parser.has_server) return .server;
        return .disabled;
    }

    fn match(byte: u8, needle: []const u8, index: *usize) bool {
        if (byte == needle[index.*]) {
            index.* += 1;
            if (index.* == needle.len) {
                index.* = 0;
                return true;
            }
        } else {
            index.* = @intFromBool(byte == needle[0]);
        }
        return false;
    }
};

/// One serialized stderr protocol line. Generated codecs construct this only
/// after `enabled` succeeds, so disabled tracing pays none of its cost.
pub const Line = struct {
    storage: [1024]u8 = undefined,
    used: usize = 0,
    first_argument: bool = true,

    pub fn begin(sent: bool, interface: []const u8, object_id: u32, message: []const u8) Line {
        while (!output_lock.tryLock()) _ = linux.sched_yield();
        var line: Line = .{};
        var time: linux.timespec = undefined;
        const clock_result = linux.clock_gettime(.REALTIME, &time);
        const milliseconds: u32 = if (linux.errno(clock_result) == .SUCCESS)
            @truncate(@as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / 1_000_000)
        else
            0;
        line.print("[{d: >7}.{d:0>3}] {s}{s}#{d}.{s}(", .{
            milliseconds / 1000,
            milliseconds % 1000,
            if (sent) " -> " else "",
            interface,
            object_id,
            message,
        });
        return line;
    }

    pub fn finish(line: *Line) void {
        line.raw(")\n");
        line.flush();
        output_lock.unlock();
    }

    pub fn int(line: *Line, value: i32) void {
        line.separator();
        line.print("{d}", .{value});
    }

    pub fn uint(line: *Line, value: u32) void {
        line.separator();
        line.print("{d}", .{value});
    }

    pub fn fixed(line: *Line, value: i32) void {
        line.separator();
        line.print("{d:.6}", .{@as(f64, @floatFromInt(value)) / 256.0});
    }

    pub fn string(line: *Line, value: ?[]const u8) void {
        line.separator();
        if (value) |bytes| {
            line.raw("\"");
            line.raw(bytes);
            line.raw("\"");
        } else line.raw("nil");
    }

    pub fn object(line: *Line, interface: ?[]const u8, object_id: ?u32) void {
        line.separator();
        if (object_id) |id| {
            line.print("{s}#{d}", .{ interface orelse "unknown", id });
        } else line.raw("nil");
    }

    pub fn newId(line: *Line, interface: []const u8, object_id: u32) void {
        line.separator();
        line.print("new id {s}#{d}", .{ interface, object_id });
    }

    pub fn array(line: *Line, value: ?[]const u8) void {
        line.separator();
        line.print("array[{d}]", .{if (value) |bytes| bytes.len else 0});
    }

    pub fn fd(line: *Line, value: linux.fd_t) void {
        line.separator();
        line.print("fd {d}", .{value});
    }

    fn separator(line: *Line) void {
        if (line.first_argument) {
            line.first_argument = false;
        } else line.raw(", ");
    }

    fn print(line: *Line, comptime format: []const u8, arguments: anytype) void {
        var storage: [128]u8 = undefined;
        const rendered = std.fmt.bufPrint(&storage, format, arguments) catch return;
        line.raw(rendered);
    }

    fn raw(line: *Line, bytes: []const u8) void {
        var remaining = bytes;
        while (remaining.len > 0) {
            if (line.used == line.storage.len) line.flush();
            const count = @min(remaining.len, line.storage.len - line.used);
            @memcpy(line.storage[line.used..][0..count], remaining[0..count]);
            line.used += count;
            remaining = remaining[count..];
        }
    }

    fn flush(line: *Line) void {
        var written: usize = 0;
        while (written < line.used) {
            const result = linux.write(2, line.storage[written..].ptr, line.used - written);
            switch (linux.errno(result)) {
                .SUCCESS => written += result,
                .INTR => continue,
                else => break,
            }
        }
        line.used = 0;
    }
};

test "parses libwayland debug values across input chunks" {
    const cases = [_]struct { value: []const u8, expected: State }{
        .{ .value = "WAYLAND_DEBUG=1\x00", .expected = .both },
        .{ .value = "OTHER=1\x00WAYLAND_DEBUG=client\x00", .expected = .client },
        .{ .value = "WAYLAND_DEBUG=server\x00", .expected = .server },
        .{ .value = "WAYLAND_DEBUG=server-client\x00", .expected = .both },
        .{ .value = "WAYLAND_DEBUG=0\x00", .expected = .disabled },
    };
    for (cases) |case| {
        for (0..case.value.len + 1) |split| {
            var parser: EnvironmentParser = .{};
            const first = parser.consume(case.value[0..split]);
            const actual = first orelse parser.consume(case.value[split..]) orelse parser.finish();
            try std.testing.expectEqual(case.expected, actual);
        }
    }
}
