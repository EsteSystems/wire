const std = @import("std");
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenType = lexer.TokenType;
const Lexer = lexer.Lexer;

/// AST Node types for wire commands
pub const NodeType = enum {
    // Top-level
    COMMAND,
    PIPELINE,

    // Subjects
    INTERFACE_SUBJECT,
    ROUTE_SUBJECT,
    BOND_SUBJECT,
    BRIDGE_SUBJECT,
    VLAN_SUBJECT,

    // Actions
    SHOW_ACTION,
    SET_ACTION,
    ADD_ACTION,
    DEL_ACTION,
    CREATE_ACTION,

    // Attribute nodes
    STATE_ATTR,
    MTU_ATTR,
    ADDRESS_ATTR,
    VIA_ATTR,
    DEV_ATTR,
    METRIC_ATTR,
    MODE_ATTR,
    MEMBERS_ATTR,
};

/// An attribute in a command (e.g., state up, mtu 9000, via 10.0.0.1)
pub const Attribute = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Represents a parsed command
pub const Command = struct {
    subject: Subject,
    action: Action,
    attributes: []Attribute,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        allocator.free(self.attributes);
    }
};

/// The subject of a command (interface, route, bond, etc.)
pub const Subject = union(enum) {
    interface: InterfaceSubject,
    route: RouteSubject,
    bond: BondSubject,
    bridge: BridgeSubject,
    vlan: VlanSubject,
    analyze: void,
};

pub const InterfaceSubject = struct {
    name: ?[]const u8,
};

pub const RouteSubject = struct {
    destination: ?[]const u8, // IP/prefix or "default"
};

pub const BondSubject = struct {
    name: ?[]const u8,
};

pub const BridgeSubject = struct {
    name: ?[]const u8,
};

pub const VlanSubject = struct {
    id: ?u16,
    parent: ?[]const u8,
};

/// The action to perform
pub const Action = union(enum) {
    show: void,
    set: SetAction,
    add: AddAction,
    del: DelAction,
    create: void,
    delete: void,
    none: void, // For listing (e.g., "wire interface" with no action)
};

pub const SetAction = struct {
    attr: []const u8,
    value: []const u8,
};

pub const AddAction = struct {
    value: ?[]const u8, // IP address for interface, destination for route
};

pub const DelAction = struct {
    value: ?[]const u8,
};

/// Parse error types
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidCommand,
    InvalidSubject,
    InvalidAction,
    InvalidAttribute,
    MissingValue,
    OutOfMemory,
};

/// Parser for wire command syntax
pub const Parser = struct {
    tokens: []const Token,
    current: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(tokens: []const Token, allocator: std.mem.Allocator) Self {
        return Self{
            .tokens = tokens,
            .current = 0,
            .allocator = allocator,
        };
    }

    /// Parse a single command
    pub fn parseCommand(self: *Self) ParseError!Command {
        // Skip comments and newlines at start
        self.skipWhitespace();

        if (self.isAtEnd()) {
            return ParseError.UnexpectedEof;
        }

        // Parse subject
        const subject = try self.parseSubject();

        // Parse action (optional for listing commands)
        const action = self.parseAction() catch Action{ .none = {} };

        // Parse attributes
        var attrs = std.ArrayList(Attribute).init(self.allocator);
        errdefer attrs.deinit();

        while (!self.isAtEnd() and !self.check(.NEWLINE) and !self.check(.PIPE) and !self.check(.EOF)) {
            if (try self.parseAttribute()) |attr| {
                try attrs.append(attr);
            } else {
                break;
            }
        }

        return Command{
            .subject = subject,
            .action = action,
            .attributes = try attrs.toOwnedSlice(),
        };
    }

    /// Parse multiple commands (for config files)
    pub fn parseCommands(self: *Self) ParseError![]Command {
        var commands = std.ArrayList(Command).init(self.allocator);
        errdefer {
            for (commands.items) |*cmd| {
                cmd.deinit(self.allocator);
            }
            commands.deinit();
        }

        while (!self.isAtEnd()) {
            self.skipWhitespace();

            if (self.isAtEnd()) break;

            // Skip empty lines
            if (self.check(.NEWLINE)) {
                _ = self.advance();
                continue;
            }

            // Skip comments
            if (self.check(.COMMENT)) {
                _ = self.advance();
                continue;
            }

            const cmd = try self.parseCommand();
            try commands.append(cmd);

            // Skip trailing newline/pipe
            if (self.check(.NEWLINE) or self.check(.PIPE)) {
                _ = self.advance();
            }
        }

        return commands.toOwnedSlice();
    }

    // Subject parsing

    fn parseSubject(self: *Self) ParseError!Subject {
        const token = self.peek();

        return switch (token.type) {
            .INTERFACE => {
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;
                return Subject{ .interface = .{ .name = name } };
            },
            .ROUTE => {
                _ = self.advance();
                // Check for destination (IP or "default")
                var dest: ?[]const u8 = null;
                if (!self.isAtEnd()) {
                    if (self.check(.DEFAULT)) {
                        dest = self.advance().lexeme;
                    } else if (self.check(.IP_ADDRESS)) {
                        dest = self.advance().lexeme;
                    }
                }
                return Subject{ .route = .{ .destination = dest } };
            },
            .BOND => {
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;
                return Subject{ .bond = .{ .name = name } };
            },
            .BRIDGE => {
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;
                return Subject{ .bridge = .{ .name = name } };
            },
            .VLAN => {
                _ = self.advance();
                var id: ?u16 = null;
                var parent: ?[]const u8 = null;

                // Parse VLAN ID
                if (!self.isAtEnd() and self.check(.NUMBER)) {
                    const num_str = self.advance().lexeme;
                    id = std.fmt.parseInt(u16, num_str, 10) catch null;
                }

                // Parse "on <parent>"
                if (!self.isAtEnd() and self.check(.ON)) {
                    _ = self.advance();
                    if (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                        parent = self.advance().lexeme;
                    }
                }

                return Subject{ .vlan = .{ .id = id, .parent = parent } };
            },
            .ANALYZE => {
                _ = self.advance();
                return Subject{ .analyze = {} };
            },
            else => ParseError.InvalidSubject,
        };
    }

    // Action parsing

    fn parseAction(self: *Self) ParseError!Action {
        if (self.isAtEnd()) return Action{ .none = {} };

        const token = self.peek();

        return switch (token.type) {
            .SHOW => {
                _ = self.advance();
                return Action{ .show = {} };
            },
            .SET => {
                _ = self.advance();
                // Expect attribute name and value
                if (self.isAtEnd()) return ParseError.MissingValue;

                const attr_token = self.advance();
                const attr_name = attr_token.lexeme;

                if (self.isAtEnd()) return ParseError.MissingValue;

                const value_token = self.advance();
                const value = value_token.lexeme;

                return Action{ .set = .{ .attr = attr_name, .value = value } };
            },
            .ADD => {
                _ = self.advance();
                // Value is optional (depends on context)
                var value: ?[]const u8 = null;
                if (!self.isAtEnd() and (self.check(.IP_ADDRESS) or self.check(.DEFAULT) or self.check(.IDENTIFIER))) {
                    value = self.advance().lexeme;
                }
                return Action{ .add = .{ .value = value } };
            },
            .DEL => {
                _ = self.advance();
                var value: ?[]const u8 = null;
                if (!self.isAtEnd() and (self.check(.IP_ADDRESS) or self.check(.DEFAULT) or self.check(.IDENTIFIER))) {
                    value = self.advance().lexeme;
                }
                return Action{ .del = .{ .value = value } };
            },
            .CREATE => {
                _ = self.advance();
                return Action{ .create = {} };
            },
            .DELETE => {
                _ = self.advance();
                return Action{ .delete = {} };
            },
            .ADDRESS => {
                // "interface eth0 address 10.0.0.1/24" - address as verb
                _ = self.advance();
                var value: ?[]const u8 = null;

                // Check for "del" subcommand
                if (!self.isAtEnd() and self.check(.DEL)) {
                    _ = self.advance();
                    if (!self.isAtEnd() and self.check(.IP_ADDRESS)) {
                        value = self.advance().lexeme;
                    }
                    return Action{ .del = .{ .value = value } };
                }

                if (!self.isAtEnd() and self.check(.IP_ADDRESS)) {
                    value = self.advance().lexeme;
                }
                return Action{ .add = .{ .value = value } };
            },
            else => Action{ .none = {} },
        };
    }

    // Attribute parsing

    fn parseAttribute(self: *Self) ParseError!?Attribute {
        if (self.isAtEnd()) return null;

        const token = self.peek();

        return switch (token.type) {
            .VIA => {
                _ = self.advance();
                if (self.isAtEnd()) return ParseError.MissingValue;
                const value = self.advance().lexeme;
                return Attribute{ .name = "via", .value = value };
            },
            .DEV => {
                _ = self.advance();
                if (self.isAtEnd()) return ParseError.MissingValue;
                const value = self.advance().lexeme;
                return Attribute{ .name = "dev", .value = value };
            },
            .METRIC => {
                _ = self.advance();
                if (self.isAtEnd()) return ParseError.MissingValue;
                const value = self.advance().lexeme;
                return Attribute{ .name = "metric", .value = value };
            },
            .MODE => {
                _ = self.advance();
                if (self.isAtEnd()) return ParseError.MissingValue;
                const value = self.advance().lexeme;
                return Attribute{ .name = "mode", .value = value };
            },
            .MEMBERS => {
                _ = self.advance();
                // Collect all following identifiers as members
                var members = std.ArrayList(u8).init(self.allocator);
                defer members.deinit();

                while (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                    const member = self.advance().lexeme;
                    if (members.items.len > 0) {
                        try members.append(' ');
                    }
                    try members.appendSlice(member);
                }

                if (members.items.len == 0) return ParseError.MissingValue;

                const value = try self.allocator.dupe(u8, members.items);
                return Attribute{ .name = "members", .value = value };
            },
            .ON => {
                _ = self.advance();
                if (self.isAtEnd()) return ParseError.MissingValue;
                const value = self.advance().lexeme;
                return Attribute{ .name = "on", .value = value };
            },
            .STATE => {
                _ = self.advance();
                if (self.isAtEnd()) return ParseError.MissingValue;
                const value = self.advance().lexeme;
                return Attribute{ .name = "state", .value = value };
            },
            .MTU => {
                _ = self.advance();
                if (self.isAtEnd()) return ParseError.MissingValue;
                const value = self.advance().lexeme;
                return Attribute{ .name = "mtu", .value = value };
            },
            else => null,
        };
    }

    // Helper methods

    fn peek(self: *Self) Token {
        if (self.current >= self.tokens.len) {
            return Token{ .type = .EOF, .lexeme = "", .line = 0, .column = 0 };
        }
        return self.tokens[self.current];
    }

    fn advance(self: *Self) Token {
        if (!self.isAtEnd()) {
            self.current += 1;
        }
        return self.tokens[self.current - 1];
    }

    fn check(self: *Self, token_type: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    fn isAtEnd(self: *Self) bool {
        return self.current >= self.tokens.len or self.peek().type == .EOF;
    }

    fn skipWhitespace(self: *Self) void {
        while (!self.isAtEnd()) {
            const t = self.peek().type;
            if (t == .NEWLINE or t == .COMMENT) {
                _ = self.advance();
            } else {
                break;
            }
        }
    }
};

/// Parse a command string directly
pub fn parse(source: []const u8, allocator: std.mem.Allocator) ParseError!Command {
    var lex = Lexer.init(source);
    const tokens = lex.tokenize(allocator) catch return ParseError.OutOfMemory;
    defer allocator.free(tokens);

    var parser = Parser.init(tokens, allocator);
    return parser.parseCommand();
}

/// Parse multiple commands from a config file
pub fn parseConfig(source: []const u8, allocator: std.mem.Allocator) ParseError![]Command {
    var lex = Lexer.init(source);
    const tokens = lex.tokenize(allocator) catch return ParseError.OutOfMemory;
    defer allocator.free(tokens);

    var parser = Parser.init(tokens, allocator);
    return parser.parseCommands();
}

// Tests

test "parse interface show" {
    const allocator = std.testing.allocator;
    var cmd = try parse("interface eth0 show", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .interface);
    try std.testing.expectEqualStrings("eth0", cmd.subject.interface.name.?);
    try std.testing.expect(cmd.action == .show);
}

test "parse interface list" {
    const allocator = std.testing.allocator;
    var cmd = try parse("interface", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .interface);
    try std.testing.expect(cmd.subject.interface.name == null);
    try std.testing.expect(cmd.action == .none);
}

test "parse interface set state up" {
    const allocator = std.testing.allocator;
    var cmd = try parse("interface eth0 set state up", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .interface);
    try std.testing.expectEqualStrings("eth0", cmd.subject.interface.name.?);
    try std.testing.expect(cmd.action == .set);
    try std.testing.expectEqualStrings("state", cmd.action.set.attr);
    try std.testing.expectEqualStrings("up", cmd.action.set.value);
}

test "parse interface address add" {
    const allocator = std.testing.allocator;
    var cmd = try parse("interface eth0 address 10.0.0.1/24", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .interface);
    try std.testing.expectEqualStrings("eth0", cmd.subject.interface.name.?);
    try std.testing.expect(cmd.action == .add);
    try std.testing.expectEqualStrings("10.0.0.1/24", cmd.action.add.value.?);
}

test "parse route show" {
    const allocator = std.testing.allocator;
    var cmd = try parse("route show", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .route);
    try std.testing.expect(cmd.action == .show);
}

test "parse route add default via" {
    const allocator = std.testing.allocator;
    var cmd = try parse("route add default via 10.0.0.254", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .route);
    try std.testing.expect(cmd.action == .add);
    try std.testing.expectEqualStrings("default", cmd.action.add.value.?);
    try std.testing.expect(cmd.attributes.len == 1);
    try std.testing.expectEqualStrings("via", cmd.attributes[0].name);
    try std.testing.expectEqualStrings("10.0.0.254", cmd.attributes[0].value.?);
}

test "parse route add with destination" {
    const allocator = std.testing.allocator;
    var cmd = try parse("route add 192.168.0.0/16 via 10.0.0.1", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .route);
    try std.testing.expect(cmd.action == .add);
    try std.testing.expectEqualStrings("192.168.0.0/16", cmd.action.add.value.?);
    try std.testing.expect(cmd.attributes.len == 1);
    try std.testing.expectEqualStrings("via", cmd.attributes[0].name);
}

test "parse analyze" {
    const allocator = std.testing.allocator;
    var cmd = try parse("analyze", allocator);
    defer cmd.deinit(allocator);

    try std.testing.expect(cmd.subject == .analyze);
}

test "parse config file" {
    const allocator = std.testing.allocator;
    const config =
        \\# Network configuration
        \\interface eth0 set state up
        \\interface eth0 address 10.0.0.1/24
        \\route add default via 10.0.0.254
    ;

    const commands = try parseConfig(config, allocator);
    defer {
        for (commands) |*cmd| {
            var c = cmd.*;
            c.deinit(allocator);
        }
        allocator.free(commands);
    }

    try std.testing.expect(commands.len == 3);
    try std.testing.expect(commands[0].subject == .interface);
    try std.testing.expect(commands[0].action == .set);
    try std.testing.expect(commands[1].subject == .interface);
    try std.testing.expect(commands[1].action == .add);
    try std.testing.expect(commands[2].subject == .route);
}
