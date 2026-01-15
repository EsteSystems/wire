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
        // Free subject-specific allocations
        switch (self.subject) {
            .bond => |bond| {
                if (bond.members) |members| {
                    allocator.free(members);
                }
            },
            .bridge => |bridge| {
                if (bridge.ports) |ports| {
                    allocator.free(ports);
                }
            },
            .tc => |tc| {
                if (tc.args) |args| {
                    allocator.free(args);
                }
            },
            .tunnel => |tunnel| {
                if (tunnel.args) |args| {
                    allocator.free(args);
                }
            },
            else => {},
        }
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
    veth: VethSubject,
    tc: TcSubject,
    tunnel: TunnelSubject,
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
    mode: ?[]const u8, // For create: active-backup, 802.3ad, etc.
    members: ?[]const u8, // Space-separated member names for add
};

pub const BridgeSubject = struct {
    name: ?[]const u8,
    ports: ?[]const u8, // Space-separated port names for add
};

pub const VlanSubject = struct {
    id: ?u16,
    parent: ?[]const u8,
    name: ?[]const u8, // Custom VLAN interface name
};

pub const VethSubject = struct {
    name: ?[]const u8,
    peer: ?[]const u8,
};

pub const TcSubject = struct {
    interface: ?[]const u8,
    tc_type: ?[]const u8, // qdisc, class, filter
    tc_kind: ?[]const u8, // pfifo, fq_codel, tbf, htb for qdisc; u32, fw for filter
    args: ?[]const u8, // Raw args string for complex parameters
};

pub const TunnelSubject = struct {
    tunnel_type: ?[]const u8, // vxlan, gre, gretap, geneve, ipip, sit, wireguard
    name: ?[]const u8,
    args: ?[]const u8, // Raw args string for complex parameters
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
    /// Supports both command format and block format:
    ///   Command format: interface eth0 set state up
    ///   Block format:   interface eth0
    ///                     state up
    ///                     address 10.0.0.1/24
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

            // Check for block format: subject name followed by newline+indent
            if (self.check(.INTERFACE)) {
                // Parse interface subject
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;

                // Check if this is block format (newline followed by indent)
                if (name != null and self.check(.NEWLINE)) {
                    const saved_pos = self.current;
                    _ = self.advance(); // consume newline

                    if (self.check(.INDENT)) {
                        // Block format - parse indented sub-commands
                        try self.parseBlockCommands(&commands, name.?);
                        continue;
                    } else {
                        // Not block format, restore position and parse normally
                        self.current = saved_pos;
                    }
                }

                // Regular command format - continue parsing action
                const action = self.parseAction() catch Action{ .none = {} };

                var attrs = std.ArrayList(Attribute).init(self.allocator);
                errdefer attrs.deinit();

                while (!self.isAtEnd() and !self.check(.NEWLINE) and !self.check(.PIPE) and !self.check(.EOF)) {
                    if (try self.parseAttribute()) |attr| {
                        try attrs.append(attr);
                    } else {
                        break;
                    }
                }

                try commands.append(Command{
                    .subject = Subject{ .interface = .{ .name = name } },
                    .action = action,
                    .attributes = try attrs.toOwnedSlice(),
                });
            } else if (self.check(.BOND)) {
                // Parse bond command: bond <name> create mode <mode>
                //                  or: bond <name> add <member> [member...]
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;

                var action = Action{ .none = {} };
                var mode: ?[]const u8 = null;
                var members: ?[]const u8 = null;

                if (!self.isAtEnd()) {
                    if (self.check(.CREATE)) {
                        _ = self.advance();
                        action = Action{ .create = {} };
                        // Check for mode
                        if (!self.isAtEnd() and self.check(.MODE)) {
                            _ = self.advance();
                            if (!self.isAtEnd()) {
                                mode = self.advance().lexeme;
                            }
                        }
                    } else if (self.check(.ADD)) {
                        _ = self.advance();
                        action = Action{ .add = .{ .value = null } };
                        // Collect member names
                        var member_list = std.ArrayList(u8).init(self.allocator);
                        defer member_list.deinit();
                        while (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                            if (member_list.items.len > 0) {
                                try member_list.append(' ');
                            }
                            try member_list.appendSlice(self.advance().lexeme);
                        }
                        if (member_list.items.len > 0) {
                            members = try self.allocator.dupe(u8, member_list.items);
                        }
                    }
                }

                try commands.append(Command{
                    .subject = Subject{ .bond = .{ .name = name, .mode = mode, .members = members } },
                    .action = action,
                    .attributes = &[_]Attribute{},
                });
            } else if (self.check(.BRIDGE)) {
                // Parse bridge command: bridge <name> create
                //                    or: bridge <name> add <port> [port...]
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;

                var action = Action{ .none = {} };
                var ports: ?[]const u8 = null;

                if (!self.isAtEnd()) {
                    if (self.check(.CREATE)) {
                        _ = self.advance();
                        action = Action{ .create = {} };
                    } else if (self.check(.ADD)) {
                        _ = self.advance();
                        action = Action{ .add = .{ .value = null } };
                        // Collect port names
                        var port_list = std.ArrayList(u8).init(self.allocator);
                        defer port_list.deinit();
                        while (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                            if (port_list.items.len > 0) {
                                try port_list.append(' ');
                            }
                            try port_list.appendSlice(self.advance().lexeme);
                        }
                        if (port_list.items.len > 0) {
                            ports = try self.allocator.dupe(u8, port_list.items);
                        }
                    }
                }

                try commands.append(Command{
                    .subject = Subject{ .bridge = .{ .name = name, .ports = ports } },
                    .action = action,
                    .attributes = &[_]Attribute{},
                });
            } else if (self.check(.VETH)) {
                // Parse veth command: veth <name> peer <peer>
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;

                var peer: ?[]const u8 = null;
                var action = Action{ .none = {} };

                if (!self.isAtEnd() and self.check(.PEER)) {
                    _ = self.advance();
                    action = Action{ .create = {} };
                    if (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                        peer = self.advance().lexeme;
                    }
                }

                try commands.append(Command{
                    .subject = Subject{ .veth = .{ .name = name, .peer = peer } },
                    .action = action,
                    .attributes = &[_]Attribute{},
                });
            } else if (self.check(.VLAN)) {
                // Parse vlan command: vlan <id> on <parent> [name <name>]
                //                  or: vlan <name> delete
                _ = self.advance();

                var id: ?u16 = null;
                var parent: ?[]const u8 = null;
                var vlan_name: ?[]const u8 = null;
                var action = Action{ .create = {} };

                // First token could be ID (number) or name (identifier)
                if (!self.isAtEnd()) {
                    if (self.check(.NUMBER)) {
                        const num_str = self.advance().lexeme;
                        id = std.fmt.parseInt(u16, num_str, 10) catch null;
                    } else if (self.check(.IDENTIFIER)) {
                        vlan_name = self.advance().lexeme;
                    }
                }

                // Check for "on <parent>"
                if (!self.isAtEnd() and self.check(.ON)) {
                    _ = self.advance();
                    if (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                        parent = self.advance().lexeme;
                    }
                }

                // Check for "id <id>" (alternative syntax)
                if (!self.isAtEnd() and self.check(.ID)) {
                    _ = self.advance();
                    if (!self.isAtEnd() and self.check(.NUMBER)) {
                        const num_str = self.advance().lexeme;
                        id = std.fmt.parseInt(u16, num_str, 10) catch null;
                    }
                }

                // Check for "delete"
                if (!self.isAtEnd() and self.check(.DELETE)) {
                    _ = self.advance();
                    action = Action{ .delete = {} };
                }

                try commands.append(Command{
                    .subject = Subject{ .vlan = .{ .id = id, .parent = parent, .name = vlan_name } },
                    .action = action,
                    .attributes = &[_]Attribute{},
                });
            } else if (self.check(.TC)) {
                // Parse tc command: tc <interface> add <type> [options...]
                //                or: tc <interface> class add <classid> rate <rate> ...
                //                or: tc <interface> filter add <type> ...
                _ = self.advance();

                var interface: ?[]const u8 = null;
                var tc_type: ?[]const u8 = null;
                var tc_kind: ?[]const u8 = null;
                var action = Action{ .none = {} };

                // Parse interface name
                if (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                    interface = self.advance().lexeme;
                }

                // Collect remaining tokens as args
                var args_list = std.ArrayList(u8).init(self.allocator);
                defer args_list.deinit();

                while (!self.isAtEnd() and !self.check(.NEWLINE) and !self.check(.PIPE) and !self.check(.EOF)) {
                    const token = self.advance();

                    // Check for action keywords
                    if (std.mem.eql(u8, token.lexeme, "add")) {
                        action = Action{ .add = .{ .value = null } };
                    } else if (std.mem.eql(u8, token.lexeme, "del") or std.mem.eql(u8, token.lexeme, "delete")) {
                        action = Action{ .delete = {} };
                    } else if (std.mem.eql(u8, token.lexeme, "class")) {
                        tc_type = "class";
                    } else if (std.mem.eql(u8, token.lexeme, "filter")) {
                        tc_type = "filter";
                    } else if (tc_kind == null and tc_type == null and
                        (std.mem.eql(u8, token.lexeme, "pfifo") or
                        std.mem.eql(u8, token.lexeme, "fq_codel") or
                        std.mem.eql(u8, token.lexeme, "tbf") or
                        std.mem.eql(u8, token.lexeme, "htb")))
                    {
                        tc_type = "qdisc";
                        tc_kind = token.lexeme;
                    } else {
                        // Add to args
                        if (args_list.items.len > 0) {
                            try args_list.append(' ');
                        }
                        try args_list.appendSlice(token.lexeme);
                    }
                }

                var args: ?[]const u8 = null;
                if (args_list.items.len > 0) {
                    args = try self.allocator.dupe(u8, args_list.items);
                }

                try commands.append(Command{
                    .subject = Subject{ .tc = .{
                        .interface = interface,
                        .tc_type = tc_type,
                        .tc_kind = tc_kind,
                        .args = args,
                    } },
                    .action = action,
                    .attributes = &[_]Attribute{},
                });
            } else if (self.check(.TUNNEL)) {
                // Parse tunnel command: tunnel <type> <name> [options...]
                _ = self.advance();

                var tunnel_type: ?[]const u8 = null;
                var name: ?[]const u8 = null;
                var action = Action{ .create = {} };

                // Parse tunnel type
                if (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                    const ttype = self.advance().lexeme;
                    if (std.mem.eql(u8, ttype, "delete") or std.mem.eql(u8, ttype, "del")) {
                        action = Action{ .delete = {} };
                        // Next token is the name
                        if (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                            name = self.advance().lexeme;
                        }
                    } else {
                        tunnel_type = ttype;
                        // Next token is the name
                        if (!self.isAtEnd() and self.check(.IDENTIFIER)) {
                            name = self.advance().lexeme;
                        }
                    }
                }

                // Collect remaining tokens as args
                var args_list = std.ArrayList(u8).init(self.allocator);
                defer args_list.deinit();

                while (!self.isAtEnd() and !self.check(.NEWLINE) and !self.check(.PIPE) and !self.check(.EOF)) {
                    if (args_list.items.len > 0) {
                        try args_list.append(' ');
                    }
                    try args_list.appendSlice(self.advance().lexeme);
                }

                var args: ?[]const u8 = null;
                if (args_list.items.len > 0) {
                    args = try self.allocator.dupe(u8, args_list.items);
                }

                try commands.append(Command{
                    .subject = Subject{ .tunnel = .{
                        .tunnel_type = tunnel_type,
                        .name = name,
                        .args = args,
                    } },
                    .action = action,
                    .attributes = &[_]Attribute{},
                });
            } else {
                // Parse other command types normally
                const cmd = try self.parseCommand();
                try commands.append(cmd);
            }

            // Skip trailing newline/pipe
            if (self.check(.NEWLINE) or self.check(.PIPE)) {
                _ = self.advance();
            }
        }

        return commands.toOwnedSlice();
    }

    /// Parse block format sub-commands for an interface
    fn parseBlockCommands(self: *Self, commands: *std.ArrayList(Command), interface_name: []const u8) ParseError!void {
        while (!self.isAtEnd()) {
            // Skip empty lines
            if (self.check(.NEWLINE)) {
                _ = self.advance();
                continue;
            }

            // Skip comments on indented lines
            if (self.check(.COMMENT)) {
                _ = self.advance();
                continue;
            }

            // Check for indent - if no indent, we're done with block
            if (!self.check(.INDENT)) {
                break;
            }

            _ = self.advance(); // consume INDENT

            // Skip comments after indent
            if (self.check(.COMMENT)) {
                _ = self.advance();
                continue;
            }

            // Skip if we hit newline immediately (blank indented line)
            if (self.check(.NEWLINE) or self.isAtEnd()) {
                continue;
            }

            // Parse the sub-command: state, address, mtu, etc.
            const token = self.peek();

            switch (token.type) {
                .STATE => {
                    // state up/down → set state up/down
                    _ = self.advance();
                    if (self.isAtEnd()) return ParseError.MissingValue;
                    const value = self.advance().lexeme;
                    try commands.append(Command{
                        .subject = Subject{ .interface = .{ .name = interface_name } },
                        .action = Action{ .set = .{ .attr = "state", .value = value } },
                        .attributes = &[_]Attribute{},
                    });
                },
                .ADDRESS => {
                    // address 10.0.0.1/24 → address 10.0.0.1/24
                    _ = self.advance();
                    var value: ?[]const u8 = null;
                    if (!self.isAtEnd() and self.check(.IP_ADDRESS)) {
                        value = self.advance().lexeme;
                    }
                    try commands.append(Command{
                        .subject = Subject{ .interface = .{ .name = interface_name } },
                        .action = Action{ .add = .{ .value = value } },
                        .attributes = &[_]Attribute{},
                    });
                },
                .MTU => {
                    // mtu 9000 → set mtu 9000
                    _ = self.advance();
                    if (self.isAtEnd()) return ParseError.MissingValue;
                    const value = self.advance().lexeme;
                    try commands.append(Command{
                        .subject = Subject{ .interface = .{ .name = interface_name } },
                        .action = Action{ .set = .{ .attr = "mtu", .value = value } },
                        .attributes = &[_]Attribute{},
                    });
                },
                .UP => {
                    // up → set state up (shorthand)
                    _ = self.advance();
                    try commands.append(Command{
                        .subject = Subject{ .interface = .{ .name = interface_name } },
                        .action = Action{ .set = .{ .attr = "state", .value = "up" } },
                        .attributes = &[_]Attribute{},
                    });
                },
                .DOWN => {
                    // down → set state down (shorthand)
                    _ = self.advance();
                    try commands.append(Command{
                        .subject = Subject{ .interface = .{ .name = interface_name } },
                        .action = Action{ .set = .{ .attr = "state", .value = "down" } },
                        .attributes = &[_]Attribute{},
                    });
                },
                else => {
                    // Unknown sub-command in block, skip to next line
                    while (!self.isAtEnd() and !self.check(.NEWLINE)) {
                        _ = self.advance();
                    }
                },
            }

            // Skip trailing newline
            if (self.check(.NEWLINE)) {
                _ = self.advance();
            }
        }
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
                return Subject{ .bond = .{ .name = name, .mode = null, .members = null } };
            },
            .BRIDGE => {
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;
                return Subject{ .bridge = .{ .name = name, .ports = null } };
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

                return Subject{ .vlan = .{ .id = id, .parent = parent, .name = null } };
            },
            .VETH => {
                _ = self.advance();
                const name = if (!self.isAtEnd() and self.check(.IDENTIFIER))
                    self.advance().lexeme
                else
                    null;
                return Subject{ .veth = .{ .name = name, .peer = null } };
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

test "parse block format config" {
    const allocator = std.testing.allocator;
    const config =
        \\interface eth0
        \\  state up
        \\  address 10.0.0.1/24
        \\  mtu 9000
        \\interface eth1
        \\  state up
    ;

    const commands = try parseConfig(config, allocator);
    defer {
        for (commands) |*cmd| {
            var c = cmd.*;
            c.deinit(allocator);
        }
        allocator.free(commands);
    }

    try std.testing.expect(commands.len == 5);

    // interface eth0 set state up
    try std.testing.expect(commands[0].subject == .interface);
    try std.testing.expectEqualStrings("eth0", commands[0].subject.interface.name.?);
    try std.testing.expect(commands[0].action == .set);
    try std.testing.expectEqualStrings("state", commands[0].action.set.attr);
    try std.testing.expectEqualStrings("up", commands[0].action.set.value);

    // interface eth0 address 10.0.0.1/24
    try std.testing.expect(commands[1].subject == .interface);
    try std.testing.expectEqualStrings("eth0", commands[1].subject.interface.name.?);
    try std.testing.expect(commands[1].action == .add);
    try std.testing.expectEqualStrings("10.0.0.1/24", commands[1].action.add.value.?);

    // interface eth0 set mtu 9000
    try std.testing.expect(commands[2].subject == .interface);
    try std.testing.expectEqualStrings("eth0", commands[2].subject.interface.name.?);
    try std.testing.expect(commands[2].action == .set);
    try std.testing.expectEqualStrings("mtu", commands[2].action.set.attr);
    try std.testing.expectEqualStrings("9000", commands[2].action.set.value);

    // interface eth1 set state up
    try std.testing.expect(commands[3].subject == .interface);
    try std.testing.expectEqualStrings("eth1", commands[3].subject.interface.name.?);
    try std.testing.expect(commands[3].action == .set);
}
