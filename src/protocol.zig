//! Build-time Wayland protocol XML intermediate representation.
//!
//! Names and other strings borrow from the input XML. Structural slices are
//! allocator-owned and released by `Protocol.deinit`.

const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    MalformedXml,
    UnexpectedElement,
    MissingAttribute,
    DuplicateAttribute,
    UnknownAttribute,
    InvalidInteger,
    InvalidBoolean,
    InvalidArgumentType,
    InvalidNullability,
    InvalidVersion,
    DuplicateName,
    TooManyMessages,
    UnsupportedEntity,
    InvalidName,
};

pub const ArgumentType = enum {
    int,
    uint,
    fixed,
    string,
    object,
    new_id,
    array,
    fd,
};

pub const Argument = struct {
    name: []const u8,
    type: ArgumentType,
    interface: ?[]const u8 = null,
    enum_name: ?[]const u8 = null,
    allow_null: bool = false,
};

pub const Message = struct {
    name: []const u8,
    opcode: u16,
    since: u32,
    deprecated_since: ?u32,
    destructor: bool,
    arguments: []Argument,

    fn deinit(message: *Message, allocator: std.mem.Allocator) void {
        allocator.free(message.arguments);
    }
};

pub const Entry = struct {
    name: []const u8,
    value: i64,
    since: u32,
    deprecated_since: ?u32,
};

pub const Enum = struct {
    name: []const u8,
    since: u32,
    bitfield: bool,
    entries: []Entry,

    fn deinit(value: *Enum, allocator: std.mem.Allocator) void {
        allocator.free(value.entries);
    }
};

pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []Message,
    events: []Message,
    enums: []Enum,

    fn deinit(interface: *Interface, allocator: std.mem.Allocator) void {
        for (interface.requests) |*message| message.deinit(allocator);
        for (interface.events) |*message| message.deinit(allocator);
        for (interface.enums) |*value| value.deinit(allocator);
        allocator.free(interface.requests);
        allocator.free(interface.events);
        allocator.free(interface.enums);
    }
};

pub const Protocol = struct {
    name: []const u8,
    interfaces: []Interface,

    pub fn parse(allocator: std.mem.Allocator, xml: []const u8) Error!Protocol {
        var parser: Parser = .{ .allocator = allocator };
        errdefer parser.deinit();
        var tokenizer: Tokenizer = .{ .xml = xml };
        while (try tokenizer.next()) |tag| try parser.consume(tag);
        return parser.finish();
    }

    pub fn deinit(protocol: *Protocol, allocator: std.mem.Allocator) void {
        for (protocol.interfaces) |*interface| interface.deinit(allocator);
        allocator.free(protocol.interfaces);
        protocol.* = undefined;
    }
};

const MessageKind = enum { request, event };

const MessageBuilder = struct {
    name: []const u8,
    kind: MessageKind,
    since: u32,
    deprecated_since: ?u32,
    destructor: bool,
    arguments: std.ArrayList(Argument) = .empty,

    fn deinit(builder: *MessageBuilder, allocator: std.mem.Allocator) void {
        builder.arguments.deinit(allocator);
    }
};

const EnumBuilder = struct {
    name: []const u8,
    since: u32,
    bitfield: bool,
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(builder: *EnumBuilder, allocator: std.mem.Allocator) void {
        builder.entries.deinit(allocator);
    }
};

const InterfaceBuilder = struct {
    name: []const u8,
    version: u32,
    requests: std.ArrayList(Message) = .empty,
    events: std.ArrayList(Message) = .empty,
    enums: std.ArrayList(Enum) = .empty,

    fn deinit(builder: *InterfaceBuilder, allocator: std.mem.Allocator) void {
        for (builder.requests.items) |*message| message.deinit(allocator);
        for (builder.events.items) |*message| message.deinit(allocator);
        for (builder.enums.items) |*value| value.deinit(allocator);
        builder.requests.deinit(allocator);
        builder.events.deinit(allocator);
        builder.enums.deinit(allocator);
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    protocol_name: ?[]const u8 = null,
    protocol_open: bool = false,
    protocol_closed: bool = false,
    interfaces: std.ArrayList(Interface) = .empty,
    interface: ?InterfaceBuilder = null,
    message: ?MessageBuilder = null,
    enumeration: ?EnumBuilder = null,
    entry_open: bool = false,
    ignored_depth: usize = 0,

    fn deinit(parser: *Parser) void {
        if (parser.message) |*message| message.deinit(parser.allocator);
        if (parser.enumeration) |*value| value.deinit(parser.allocator);
        if (parser.interface) |*interface| interface.deinit(parser.allocator);
        for (parser.interfaces.items) |*interface| interface.deinit(parser.allocator);
        parser.interfaces.deinit(parser.allocator);
    }

    fn consume(parser: *Parser, tag: Tag) Error!void {
        if (parser.ignored_depth > 0) {
            if (tag.kind == .start) parser.ignored_depth += 1;
            if (tag.kind == .end) parser.ignored_depth -= 1;
            return;
        }
        if (std.mem.eql(u8, tag.name, "description") or
            std.mem.eql(u8, tag.name, "copyright"))
        {
            if (tag.kind == .start) parser.ignored_depth = 1;
            return;
        }
        if (std.mem.eql(u8, tag.name, "protocol")) return parser.protocolTag(tag);
        if (std.mem.eql(u8, tag.name, "interface")) return parser.interfaceTag(tag);
        if (std.mem.eql(u8, tag.name, "request")) return parser.messageTag(tag, .request);
        if (std.mem.eql(u8, tag.name, "event")) return parser.messageTag(tag, .event);
        if (std.mem.eql(u8, tag.name, "arg")) return parser.argumentTag(tag);
        if (std.mem.eql(u8, tag.name, "enum")) return parser.enumTag(tag);
        if (std.mem.eql(u8, tag.name, "entry")) return parser.entryTag(tag);
        return error.UnexpectedElement;
    }

    fn protocolTag(parser: *Parser, tag: Tag) Error!void {
        switch (tag.kind) {
            .start => {
                if (parser.protocol_open or parser.protocol_closed) return error.UnexpectedElement;
                try tag.attributes.ensureOnly(&.{"name"});
                parser.protocol_name = try tag.attributes.required("name");
                try validateName(parser.protocol_name.?);
                parser.protocol_open = true;
            },
            .end => {
                if (!parser.protocol_open or parser.interface != null or
                    parser.message != null or parser.enumeration != null)
                    return error.UnexpectedElement;
                parser.protocol_open = false;
                parser.protocol_closed = true;
            },
            .empty => return error.UnexpectedElement,
        }
    }

    fn interfaceTag(parser: *Parser, tag: Tag) Error!void {
        if (!parser.protocol_open or parser.message != null or parser.enumeration != null)
            return error.UnexpectedElement;
        switch (tag.kind) {
            .start => {
                if (parser.interface != null) return error.UnexpectedElement;
                try tag.attributes.ensureOnly(&.{ "name", "version", "frozen" });
                const name = try tag.attributes.required("name");
                try validateName(name);
                try ensureUniqueInterface(parser.interfaces.items, name);
                const version = try tag.attributes.requiredUnsigned("version");
                if (version == 0) return error.InvalidVersion;
                _ = try tag.attributes.optionalBoolean("frozen");
                parser.interface = .{ .name = name, .version = version };
            },
            .end => try parser.finishInterface(),
            .empty => return error.UnexpectedElement,
        }
    }

    fn messageTag(parser: *Parser, tag: Tag, kind: MessageKind) Error!void {
        if (parser.interface == null or parser.enumeration != null) return error.UnexpectedElement;
        switch (tag.kind) {
            .start, .empty => {
                if (parser.message != null) return error.UnexpectedElement;
                try tag.attributes.ensureOnly(&.{ "name", "type", "since", "deprecated-since" });
                const name = try tag.attributes.required("name");
                try validateName(name);
                const interface = &parser.interface.?;
                const messages = if (kind == .request)
                    interface.requests.items
                else
                    interface.events.items;
                try ensureUniqueMessage(messages, name);
                const since = try tag.attributes.optionalUnsigned("since") orelse 1;
                if (since == 0 or since > interface.version) return error.InvalidVersion;
                const message_type = try tag.attributes.optional("type");
                if (message_type) |value| {
                    if (!std.mem.eql(u8, value, "destructor")) return error.UnexpectedElement;
                }
                parser.message = .{
                    .name = name,
                    .kind = kind,
                    .since = since,
                    .deprecated_since = try tag.attributes.optionalUnsigned("deprecated-since"),
                    .destructor = message_type != null,
                };
                if (tag.kind == .empty) try parser.finishMessage();
            },
            .end => {
                if (parser.message == null or parser.message.?.kind != kind)
                    return error.UnexpectedElement;
                try parser.finishMessage();
            },
        }
    }

    fn argumentTag(parser: *Parser, tag: Tag) Error!void {
        if (tag.kind != .empty or parser.message == null) return error.UnexpectedElement;
        try tag.attributes.ensureOnly(&.{
            "name", "type", "interface", "enum", "allow-null", "summary",
        });
        const name = try tag.attributes.required("name");
        try validateName(name);
        for (parser.message.?.arguments.items) |argument| {
            if (std.mem.eql(u8, argument.name, name)) return error.DuplicateName;
        }
        const type_name = try tag.attributes.required("type");
        const argument_type = std.meta.stringToEnum(ArgumentType, type_name) orelse
            return error.InvalidArgumentType;
        const allow_null = try tag.attributes.optionalBoolean("allow-null") orelse false;
        if (allow_null and switch (argument_type) {
            .string, .object, .array => false,
            else => true,
        }) return error.InvalidNullability;
        try parser.message.?.arguments.append(parser.allocator, .{
            .name = name,
            .type = argument_type,
            .interface = try tag.attributes.optional("interface"),
            .enum_name = try tag.attributes.optional("enum"),
            .allow_null = allow_null,
        });
    }

    fn enumTag(parser: *Parser, tag: Tag) Error!void {
        if (parser.interface == null or parser.message != null or parser.entry_open)
            return error.UnexpectedElement;
        switch (tag.kind) {
            .start, .empty => {
                if (parser.enumeration != null) return error.UnexpectedElement;
                try tag.attributes.ensureOnly(&.{ "name", "since", "bitfield" });
                const name = try tag.attributes.required("name");
                try validateName(name);
                for (parser.interface.?.enums.items) |value| {
                    if (std.mem.eql(u8, value.name, name)) return error.DuplicateName;
                }
                const since = try tag.attributes.optionalUnsigned("since") orelse 1;
                if (since == 0 or since > parser.interface.?.version)
                    return error.InvalidVersion;
                parser.enumeration = .{
                    .name = name,
                    .since = since,
                    .bitfield = try tag.attributes.optionalBoolean("bitfield") orelse false,
                };
                if (tag.kind == .empty) try parser.finishEnum();
            },
            .end => try parser.finishEnum(),
        }
    }

    fn entryTag(parser: *Parser, tag: Tag) Error!void {
        if (parser.enumeration == null) return error.UnexpectedElement;
        switch (tag.kind) {
            .start => {
                if (parser.entry_open) return error.UnexpectedElement;
                try parser.appendEntry(tag);
                parser.entry_open = true;
            },
            .empty => {
                if (parser.entry_open) return error.UnexpectedElement;
                try parser.appendEntry(tag);
            },
            .end => {
                if (!parser.entry_open) return error.UnexpectedElement;
                parser.entry_open = false;
            },
        }
    }

    fn appendEntry(parser: *Parser, tag: Tag) Error!void {
        try tag.attributes.ensureOnly(&.{
            "name", "value", "summary", "since", "deprecated-since",
        });
        const name = try tag.attributes.required("name");
        for (parser.enumeration.?.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return error.DuplicateName;
        }
        const since = try tag.attributes.optionalUnsigned("since") orelse 1;
        if (since == 0 or since > parser.interface.?.version) return error.InvalidVersion;
        try parser.enumeration.?.entries.append(parser.allocator, .{
            .name = name,
            .value = try tag.attributes.requiredInteger("value"),
            .since = since,
            .deprecated_since = try tag.attributes.optionalUnsigned("deprecated-since"),
        });
    }

    fn finishMessage(parser: *Parser) Error!void {
        var builder = parser.message orelse return error.UnexpectedElement;
        parser.message = null;
        errdefer builder.deinit(parser.allocator);
        const interface = &parser.interface.?;
        const destination = if (builder.kind == .request)
            &interface.requests
        else
            &interface.events;
        if (destination.items.len > std.math.maxInt(u16)) return error.TooManyMessages;
        const arguments = try builder.arguments.toOwnedSlice(parser.allocator);
        errdefer parser.allocator.free(arguments);
        try destination.append(parser.allocator, .{
            .name = builder.name,
            .opcode = @intCast(destination.items.len),
            .since = builder.since,
            .deprecated_since = builder.deprecated_since,
            .destructor = builder.destructor,
            .arguments = arguments,
        });
    }

    fn finishEnum(parser: *Parser) Error!void {
        var builder = parser.enumeration orelse return error.UnexpectedElement;
        parser.enumeration = null;
        errdefer builder.deinit(parser.allocator);
        const entries = try builder.entries.toOwnedSlice(parser.allocator);
        errdefer parser.allocator.free(entries);
        try parser.interface.?.enums.append(parser.allocator, .{
            .name = builder.name,
            .since = builder.since,
            .bitfield = builder.bitfield,
            .entries = entries,
        });
    }

    fn finishInterface(parser: *Parser) Error!void {
        var builder = parser.interface orelse return error.UnexpectedElement;
        parser.interface = null;
        errdefer builder.deinit(parser.allocator);
        const requests = try builder.requests.toOwnedSlice(parser.allocator);
        errdefer {
            for (requests) |*message| message.deinit(parser.allocator);
            parser.allocator.free(requests);
        }
        const events = try builder.events.toOwnedSlice(parser.allocator);
        errdefer {
            for (events) |*message| message.deinit(parser.allocator);
            parser.allocator.free(events);
        }
        const enums = try builder.enums.toOwnedSlice(parser.allocator);
        errdefer {
            for (enums) |*value| value.deinit(parser.allocator);
            parser.allocator.free(enums);
        }
        try parser.interfaces.append(parser.allocator, .{
            .name = builder.name,
            .version = builder.version,
            .requests = requests,
            .events = events,
            .enums = enums,
        });
    }

    fn finish(parser: *Parser) Error!Protocol {
        if (!parser.protocol_closed or parser.protocol_open or parser.interface != null or
            parser.message != null or parser.enumeration != null or parser.ignored_depth != 0)
            return error.MalformedXml;
        return .{
            .name = parser.protocol_name orelse return error.MalformedXml,
            .interfaces = try parser.interfaces.toOwnedSlice(parser.allocator),
        };
    }
};

fn ensureUniqueInterface(interfaces: []const Interface, name: []const u8) Error!void {
    for (interfaces) |interface| {
        if (std.mem.eql(u8, interface.name, name)) return error.DuplicateName;
    }
}

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or
        !(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
        return error.InvalidName;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return error.InvalidName;
    }
}

fn ensureUniqueMessage(messages: []const Message, name: []const u8) Error!void {
    for (messages) |message| {
        if (std.mem.eql(u8, message.name, name)) return error.DuplicateName;
    }
}

const TagKind = enum { start, end, empty };

const Tag = struct {
    kind: TagKind,
    name: []const u8,
    attributes: Attributes,
};

const Tokenizer = struct {
    xml: []const u8,
    cursor: usize = 0,

    fn next(tokenizer: *Tokenizer) Error!?Tag {
        while (true) {
            const relative = std.mem.indexOfScalar(u8, tokenizer.xml[tokenizer.cursor..], '<') orelse {
                tokenizer.cursor = tokenizer.xml.len;
                return null;
            };
            const start = tokenizer.cursor + relative;
            if (std.mem.startsWith(u8, tokenizer.xml[start..], "<!--")) {
                const end = std.mem.indexOf(u8, tokenizer.xml[start + 4 ..], "-->") orelse
                    return error.MalformedXml;
                tokenizer.cursor = start + 4 + end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, tokenizer.xml[start..], "<?")) {
                const end = std.mem.indexOf(u8, tokenizer.xml[start + 2 ..], "?>") orelse
                    return error.MalformedXml;
                tokenizer.cursor = start + 2 + end + 2;
                continue;
            }
            if (std.mem.startsWith(u8, tokenizer.xml[start..], "<!"))
                return error.MalformedXml;

            var end = start + 1;
            var quote: ?u8 = null;
            while (end < tokenizer.xml.len) : (end += 1) {
                const byte = tokenizer.xml[end];
                if (quote) |delimiter| {
                    if (byte == delimiter) quote = null;
                } else if (byte == '\'' or byte == '"') {
                    quote = byte;
                } else if (byte == '>') break;
            }
            if (end == tokenizer.xml.len or quote != null) return error.MalformedXml;
            tokenizer.cursor = end + 1;
            var body = std.mem.trim(u8, tokenizer.xml[start + 1 .. end], " \t\r\n");
            var kind: TagKind = .start;
            if (body.len > 0 and body[0] == '/') {
                kind = .end;
                body = std.mem.trimStart(u8, body[1..], " \t\r\n");
            } else if (body.len > 0 and body[body.len - 1] == '/') {
                kind = .empty;
                body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " \t\r\n");
            }
            const name_end = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
            if (name_end == 0) return error.MalformedXml;
            const name = body[0..name_end];
            const attributes = std.mem.trimStart(u8, body[name_end..], " \t\r\n");
            if (kind == .end and attributes.len != 0) return error.MalformedXml;
            return .{ .kind = kind, .name = name, .attributes = .{ .raw = attributes } };
        }
    }
};

const Attribute = struct { name: []const u8, value: []const u8 };

const AttributeIterator = struct {
    raw: []const u8,
    cursor: usize = 0,

    fn next(iterator: *AttributeIterator) Error!?Attribute {
        while (iterator.cursor < iterator.raw.len and
            std.ascii.isWhitespace(iterator.raw[iterator.cursor]))
            iterator.cursor += 1;
        if (iterator.cursor == iterator.raw.len) return null;
        const name_start = iterator.cursor;
        while (iterator.cursor < iterator.raw.len and
            !std.ascii.isWhitespace(iterator.raw[iterator.cursor]) and
            iterator.raw[iterator.cursor] != '=')
            iterator.cursor += 1;
        if (iterator.cursor == name_start) return error.MalformedXml;
        const name = iterator.raw[name_start..iterator.cursor];
        while (iterator.cursor < iterator.raw.len and
            std.ascii.isWhitespace(iterator.raw[iterator.cursor]))
            iterator.cursor += 1;
        if (iterator.cursor == iterator.raw.len or iterator.raw[iterator.cursor] != '=')
            return error.MalformedXml;
        iterator.cursor += 1;
        while (iterator.cursor < iterator.raw.len and
            std.ascii.isWhitespace(iterator.raw[iterator.cursor]))
            iterator.cursor += 1;
        if (iterator.cursor == iterator.raw.len or
            (iterator.raw[iterator.cursor] != '"' and iterator.raw[iterator.cursor] != '\''))
            return error.MalformedXml;
        const quote = iterator.raw[iterator.cursor];
        iterator.cursor += 1;
        const value_start = iterator.cursor;
        while (iterator.cursor < iterator.raw.len and iterator.raw[iterator.cursor] != quote)
            iterator.cursor += 1;
        if (iterator.cursor == iterator.raw.len) return error.MalformedXml;
        const value = iterator.raw[value_start..iterator.cursor];
        iterator.cursor += 1;
        if (std.mem.indexOfScalar(u8, value, '&') != null) return error.UnsupportedEntity;
        return .{ .name = name, .value = value };
    }
};

const Attributes = struct {
    raw: []const u8,

    fn optional(attributes: Attributes, name: []const u8) Error!?[]const u8 {
        var iterator: AttributeIterator = .{ .raw = attributes.raw };
        var result: ?[]const u8 = null;
        while (try iterator.next()) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) {
                if (result != null) return error.DuplicateAttribute;
                result = attribute.value;
            }
        }
        return result;
    }

    fn required(attributes: Attributes, name: []const u8) Error![]const u8 {
        return try attributes.optional(name) orelse error.MissingAttribute;
    }

    fn optionalUnsigned(attributes: Attributes, name: []const u8) Error!?u32 {
        const value = try attributes.optional(name) orelse return null;
        return std.fmt.parseInt(u32, value, 0) catch error.InvalidInteger;
    }

    fn requiredUnsigned(attributes: Attributes, name: []const u8) Error!u32 {
        return try attributes.optionalUnsigned(name) orelse error.MissingAttribute;
    }

    fn requiredInteger(attributes: Attributes, name: []const u8) Error!i64 {
        const value = try attributes.required(name);
        return std.fmt.parseInt(i64, value, 0) catch error.InvalidInteger;
    }

    fn optionalBoolean(attributes: Attributes, name: []const u8) Error!?bool {
        const value = try attributes.optional(name) orelse return null;
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return error.InvalidBoolean;
    }

    fn ensureOnly(attributes: Attributes, allowed: []const []const u8) Error!void {
        var iterator: AttributeIterator = .{ .raw = attributes.raw };
        while (try iterator.next()) |attribute| {
            for (allowed) |name| {
                if (std.mem.eql(u8, attribute.name, name)) break;
            } else return error.UnknownAttribute;
        }
    }
};

test "parses messages, arguments, enums, and versions" {
    const xml =
        \\<?xml version="1.0"?>
        \\<protocol name="sample">
        \\  <interface name="wl_sample" version="3" frozen="true">
        \\    <request name="destroy" type="destructor"/>
        \\    <request name="set_title" since="2">
        \\      <arg name="title" type="string" allow-null="true"/>
        \\      <arg name="target" type="object" interface="wl_sample"/>
        \\    </request>
        \\    <event name="done"><arg name="serial" type="uint"/></event>
        \\    <enum name="state" bitfield="true">
        \\      <entry name="ready" value="0x1"/>
        \\      <entry name="failed" value="-1" since="2">
        \\        <description summary="failure">Detailed failure.</description>
        \\      </entry>
        \\    </enum>
        \\  </interface>
        \\</protocol>
    ;
    var protocol = try Protocol.parse(std.testing.allocator, xml);
    defer protocol.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sample", protocol.name);
    const interface = protocol.interfaces[0];
    try std.testing.expectEqual(@as(u32, 3), interface.version);
    try std.testing.expectEqual(@as(usize, 2), interface.requests.len);
    try std.testing.expect(interface.requests[0].destructor);
    try std.testing.expectEqual(@as(u16, 1), interface.requests[1].opcode);
    try std.testing.expect(interface.requests[1].arguments[0].allow_null);
    try std.testing.expectEqual(ArgumentType.object, interface.requests[1].arguments[1].type);
    try std.testing.expectEqual(@as(i64, -1), interface.enums[0].entries[1].value);
}

test "rejects duplicate names and invalid versions" {
    const duplicate =
        \\<protocol name="bad"><interface name="x" version="1">
        \\<request name="same"/><request name="same"/>
        \\</interface></protocol>
    ;
    try std.testing.expectError(
        error.DuplicateName,
        Protocol.parse(std.testing.allocator, duplicate),
    );
    const version =
        \\<protocol name="bad"><interface name="x" version="1">
        \\<event name="future" since="2"/>
        \\</interface></protocol>
    ;
    try std.testing.expectError(
        error.InvalidVersion,
        Protocol.parse(std.testing.allocator, version),
    );
}

test "rejects nullability for arguments without a nullable wire form" {
    const xml =
        \\<protocol name="bad"><interface name="x" version="1">
        \\<request name="create"><arg name="id" type="new_id" allow-null="true"/></request>
        \\</interface></protocol>
    ;
    try std.testing.expectError(
        error.InvalidNullability,
        Protocol.parse(std.testing.allocator, xml),
    );
}

fn parseAndDeinit(allocator: std.mem.Allocator, xml: []const u8) !void {
    var protocol = try Protocol.parse(allocator, xml);
    protocol.deinit(allocator);
}

test "parser releases every partial allocation" {
    const xml =
        \\<protocol name="sample"><interface name="sample" version="1">
        \\<request name="first"><arg name="value" type="uint"/></request>
        \\<event name="second"><arg name="text" type="string"/></event>
        \\<enum name="state"><entry name="ready" value="1"/></enum>
        \\</interface></protocol>
    ;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseAndDeinit,
        .{xml},
    );
}
