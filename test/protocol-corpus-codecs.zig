const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("corpus_protocol");

// Kept mutable so the compiler analyzes the calls without executing them. The
// values are deliberately undefined: this test checks every generated helper
// body at compile time, while the focused protocol tests exercise real data.
var execute_helpers = false;

test "all generated helpers compile" {
    @setEvalBranchQuota(1_000_000);
    inline for (comptime std.meta.declarations(protocol)) |declaration| {
        const value = @field(protocol, declaration.name);
        if (@TypeOf(value) == type and @hasDecl(value, "info")) {
            try instantiateHelpers(value);
        }
    }
}

fn instantiateHelpers(comptime Interface: type) !void {
    if (!execute_helpers) return;

    const queue: *wayring.tx.Queue = undefined;
    const message: wayring.wire.Message = undefined;
    const fds: *wayring.ancillary.FdQueue = undefined;

    inline for (@typeInfo(Interface.Request).@"union".fields) |field| {
        const request = @unionInit(
            Interface.Request,
            field.name,
            defaultValue(field.type),
        );
        _ = try Interface.requestSize(request);
        try Interface.encodeRequest(queue, 1, request);
    }
    _ = try Interface.decodeRequest(message, fds);
    if (@hasDecl(Interface, "decodeRequestObjects")) {
        const namespace: *wayring.objects.Namespace = undefined;
        _ = try Interface.decodeRequestObjects(namespace, message, fds);
    }

    inline for (@typeInfo(Interface.Event).@"union".fields) |field| {
        const event = @unionInit(
            Interface.Event,
            field.name,
            defaultValue(field.type),
        );
        _ = try Interface.eventSize(event);
        try Interface.encodeEvent(queue, 1, event);
    }
    _ = try Interface.decodeEvent(message, fds);
    if (@hasDecl(Interface, "decodeEventObjects")) {
        const namespace: *wayring.objects.Namespace = undefined;
        _ = try Interface.decodeEventObjects(namespace, message, fds);
    }

    const client_objects: *wayring.objects.ClientObjects = undefined;
    const server_objects: *wayring.objects.ServerObjects = undefined;
    const parent = defaultValue(wayring.objects.Handle);
    inline for (comptime std.meta.declarations(Interface)) |declaration| {
        if (comptime std.mem.startsWith(u8, declaration.name, "Constructor_")) {
            const suffix = declaration.name["Constructor_".len..];
            _ = try @field(Interface, "construct_" ++ suffix)(
                client_objects,
                queue,
                parent,
                defaultValue(@field(Interface, declaration.name)),
            );
        } else if (comptime std.mem.startsWith(u8, declaration.name, "NewObjects_")) {
            const suffix = declaration.name["NewObjects_".len..];
            _ = try @field(Interface, "admit_" ++ suffix)(
                server_objects,
                parent,
                defaultValue(@field(Interface, "Request_" ++ suffix)),
                defaultValue(@field(Interface, declaration.name)),
            );
        } else if (comptime std.mem.startsWith(u8, declaration.name, "EventConstructor_")) {
            const suffix = declaration.name["EventConstructor_".len..];
            _ = try @field(Interface, "construct_event_" ++ suffix)(
                protocol,
                server_objects,
                queue,
                parent,
                defaultValue(@field(Interface, declaration.name)),
            );
        } else if (comptime std.mem.startsWith(u8, declaration.name, "EventNewObjects_")) {
            const suffix = declaration.name["EventNewObjects_".len..];
            _ = try @field(Interface, "admit_event_" ++ suffix)(
                client_objects,
                parent,
                defaultValue(@field(Interface, "Event_" ++ suffix)),
                defaultValue(@field(Interface, declaration.name)),
            );
        }
    }
}

fn defaultValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .int => 0,
        .optional => null,
        .pointer => |info| switch (info.size) {
            .slice => &.{},
            else => undefined,
        },
        .@"struct" => |info| value: {
            var result: T = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = defaultValue(field.type);
            }
            break :value result;
        },
        else => @compileError("unsupported protocol value type " ++ @typeName(T)),
    };
}
