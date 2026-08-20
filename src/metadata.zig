//! Compact generated interface metadata used before typed codec dispatch.

const std = @import("std");

pub const Error = error{
    InvalidObjectVersion,
    UnknownOpcode,
    UnsupportedVersion,
};

pub const Message = struct {
    since: u32,
    destructor: bool = false,
};

pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,

    pub inline fn validateVersion(interface: Interface, version: u32) Error!void {
        if (version == 0 or version > interface.version)
            return error.InvalidObjectVersion;
    }

    pub inline fn request(
        interface: Interface,
        opcode: u16,
        object_version: u32,
    ) Error!Message {
        return interface.message(interface.requests, opcode, object_version);
    }

    pub inline fn event(
        interface: Interface,
        opcode: u16,
        object_version: u32,
    ) Error!Message {
        return interface.message(interface.events, opcode, object_version);
    }

    inline fn message(
        interface: Interface,
        messages: []const Message,
        opcode: u16,
        object_version: u32,
    ) Error!Message {
        try interface.validateVersion(object_version);
        if (opcode >= messages.len) return error.UnknownOpcode;
        const value = messages[opcode];
        if (value.since > object_version) return error.UnsupportedVersion;
        return value;
    }
};

test "validates versions, opcodes, and destructor metadata" {
    const info: Interface = .{
        .name = "sample_v1",
        .version = 3,
        .requests = &.{
            .{ .since = 1 },
            .{ .since = 2, .destructor = true },
        },
        .events = &.{.{ .since = 3 }},
    };
    try std.testing.expect(!(try info.request(0, 1)).destructor);
    try std.testing.expect((try info.request(1, 2)).destructor);
    try std.testing.expectError(error.UnsupportedVersion, info.request(1, 1));
    try std.testing.expectError(error.UnknownOpcode, info.request(2, 3));
    try std.testing.expectError(error.InvalidObjectVersion, info.event(0, 4));
    try std.testing.expectEqual(@as(u32, 3), (try info.event(0, 3)).since);
}
