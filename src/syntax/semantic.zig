const std = @import("std");
const parser = @import("parser.zig");
const Command = parser.Command;
const Subject = parser.Subject;
const Action = parser.Action;
const Attribute = parser.Attribute;

/// Semantic validation errors
pub const SemanticError = error{
    MissingInterfaceName,
    MissingRouteDestination,
    MissingGateway,
    MissingValue,
    InvalidMtu,
    InvalidState,
    InvalidVlanId,
    InvalidIpAddress,
    UnknownAttribute,
    IncompatibleAction,
    MissingBondName,
    MissingBridgeName,
    OutOfMemory,
};

/// Validation result with details
pub const ValidationResult = struct {
    valid: bool,
    errors: []const ValidationError,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.errors);
    }
};

pub const ValidationError = struct {
    message: []const u8,
    field: ?[]const u8,
};

/// Validator for wire commands
pub const Validator = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ValidationError),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .errors = std.ArrayList(ValidationError).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.errors.deinit();
    }

    /// Validate a command
    pub fn validate(self: *Self, cmd: *const Command) SemanticError!void {
        self.errors.clearRetainingCapacity();

        switch (cmd.subject) {
            .interface => |iface| try self.validateInterfaceCommand(iface, cmd.action, cmd.attributes),
            .route => |route| try self.validateRouteCommand(route, cmd.action, cmd.attributes),
            .bond => |bond| try self.validateBondCommand(bond, cmd.action, cmd.attributes),
            .bridge => |bridge| try self.validateBridgeCommand(bridge, cmd.action, cmd.attributes),
            .vlan => |vlan| try self.validateVlanCommand(vlan, cmd.action, cmd.attributes),
            .veth => |veth| try self.validateVethCommand(veth, cmd.action),
            .analyze => {}, // Always valid
            .tc => {}, // TC commands validated separately
            .tunnel => {}, // Tunnel commands validated separately
        }
    }

    /// Get validation result
    pub fn result(self: *Self) ValidationResult {
        return ValidationResult{
            .valid = self.errors.items.len == 0,
            .errors = self.errors.toOwnedSlice() catch &[_]ValidationError{},
        };
    }

    // Interface validation

    fn validateInterfaceCommand(
        self: *Self,
        iface: parser.InterfaceSubject,
        action: Action,
        attributes: []const Attribute,
    ) SemanticError!void {
        // For most actions, interface name is required
        switch (action) {
            .show, .set, .add, .del => {
                if (iface.name == null) {
                    try self.addError("Interface name is required for this action", "name");
                    return SemanticError.MissingInterfaceName;
                }
            },
            .none => {}, // Listing all interfaces - name optional
            else => {},
        }

        // Validate set action
        if (action == .set) {
            const set = action.set;
            if (std.mem.eql(u8, set.attr, "state")) {
                if (!std.mem.eql(u8, set.value, "up") and !std.mem.eql(u8, set.value, "down")) {
                    try self.addError("State must be 'up' or 'down'", "state");
                    return SemanticError.InvalidState;
                }
            } else if (std.mem.eql(u8, set.attr, "mtu")) {
                const mtu = std.fmt.parseInt(u32, set.value, 10) catch {
                    try self.addError("MTU must be a valid number", "mtu");
                    return SemanticError.InvalidMtu;
                };
                if (mtu < 68 or mtu > 65535) {
                    try self.addError("MTU must be between 68 and 65535", "mtu");
                    return SemanticError.InvalidMtu;
                }
            }
        }

        // Validate address add/del
        if (action == .add or action == .del) {
            const value = if (action == .add) action.add.value else action.del.value;
            if (value) |addr| {
                if (!isValidIpCidr(addr)) {
                    try self.addError("Invalid IP address format (expected: x.x.x.x/prefix)", "address");
                    return SemanticError.InvalidIpAddress;
                }
            } else {
                try self.addError("IP address is required", "address");
                return SemanticError.MissingValue;
            }
        }

        // Validate attributes
        for (attributes) |attr| {
            if (!isValidInterfaceAttribute(attr.name)) {
                try self.addError("Unknown attribute for interface command", attr.name);
            }
        }
    }

    // Route validation

    fn validateRouteCommand(
        self: *Self,
        route: parser.RouteSubject,
        action: Action,
        attributes: []const Attribute,
    ) SemanticError!void {
        switch (action) {
            .add => {
                // For add, we need either a destination or "default"
                if (action.add.value == null and route.destination == null) {
                    try self.addError("Route destination is required", "destination");
                    return SemanticError.MissingRouteDestination;
                }

                // Check for gateway
                var has_gateway = false;
                var has_dev = false;
                for (attributes) |attr| {
                    if (std.mem.eql(u8, attr.name, "via")) {
                        has_gateway = true;
                        if (attr.value) |gw| {
                            if (!isValidIp(gw)) {
                                try self.addError("Invalid gateway IP address", "via");
                                return SemanticError.InvalidIpAddress;
                            }
                        }
                    }
                    if (std.mem.eql(u8, attr.name, "dev")) {
                        has_dev = true;
                    }
                }

                // Need either gateway or device
                if (!has_gateway and !has_dev) {
                    try self.addError("Route requires either 'via <gateway>' or 'dev <interface>'", null);
                    return SemanticError.MissingGateway;
                }
            },
            .del => {
                // Need destination to delete
                if (action.del.value == null and route.destination == null) {
                    try self.addError("Route destination is required for deletion", "destination");
                    return SemanticError.MissingRouteDestination;
                }
            },
            .show, .none => {}, // Always valid
            else => {},
        }

        // Validate attributes
        for (attributes) |attr| {
            if (!isValidRouteAttribute(attr.name)) {
                try self.addError("Unknown attribute for route command", attr.name);
            }
        }
    }

    // Bond validation

    fn validateBondCommand(
        self: *Self,
        bond: parser.BondSubject,
        action: Action,
        attributes: []const Attribute,
    ) SemanticError!void {
        switch (action) {
            .create, .delete, .show, .add, .del => {
                if (bond.name == null) {
                    try self.addError("Bond name is required", "name");
                    return SemanticError.MissingBondName;
                }
            },
            .none => {}, // Listing all bonds
            else => {},
        }

        // Validate mode if present
        for (attributes) |attr| {
            if (std.mem.eql(u8, attr.name, "mode")) {
                if (attr.value) |mode| {
                    if (!isValidBondMode(mode)) {
                        try self.addError("Invalid bond mode", "mode");
                    }
                }
            }
        }
    }

    // Bridge validation

    fn validateBridgeCommand(
        self: *Self,
        bridge: parser.BridgeSubject,
        action: Action,
        attributes: []const Attribute,
    ) SemanticError!void {
        _ = attributes;

        switch (action) {
            .create, .delete, .show, .add, .del => {
                if (bridge.name == null) {
                    try self.addError("Bridge name is required", "name");
                    return SemanticError.MissingBridgeName;
                }
            },
            .none => {}, // Listing all bridges
            else => {},
        }
    }

    // VLAN validation

    fn validateVlanCommand(
        self: *Self,
        vlan: parser.VlanSubject,
        action: Action,
        attributes: []const Attribute,
    ) SemanticError!void {
        _ = action;
        _ = attributes;

        if (vlan.id) |id| {
            if (id < 1 or id > 4094) {
                try self.addError("VLAN ID must be between 1 and 4094", "id");
                return SemanticError.InvalidVlanId;
            }
        }
    }

    // Veth validation

    fn validateVethCommand(
        self: *Self,
        veth: parser.VethSubject,
        action: Action,
    ) SemanticError!void {
        switch (action) {
            .create => {
                if (veth.name == null) {
                    try self.addError("Veth name is required", "name");
                    return SemanticError.MissingInterfaceName;
                }
                if (veth.peer == null) {
                    try self.addError("Veth peer name is required", "peer");
                    return SemanticError.MissingInterfaceName;
                }
            },
            .delete => {
                if (veth.name == null) {
                    try self.addError("Veth name is required", "name");
                    return SemanticError.MissingInterfaceName;
                }
            },
            else => {},
        }
    }

    // Helper methods

    fn addError(self: *Self, message: []const u8, field: ?[]const u8) !void {
        try self.errors.append(ValidationError{
            .message = message,
            .field = field,
        });
    }
};

// Validation helpers

fn isValidIp(str: []const u8) bool {
    var dots: usize = 0;
    var colons: usize = 0;

    for (str) |c| {
        if (c == '.') dots += 1;
        if (c == ':') colons += 1;
    }

    // IPv4: 3 dots
    if (dots == 3) return true;

    // IPv6: multiple colons
    if (colons >= 2) return true;

    return false;
}

fn isValidIpCidr(str: []const u8) bool {
    // Check for CIDR notation
    if (std.mem.indexOfScalar(u8, str, '/')) |slash_pos| {
        const ip_part = str[0..slash_pos];
        const prefix_part = str[slash_pos + 1 ..];

        if (!isValidIp(ip_part)) return false;

        const prefix = std.fmt.parseInt(u8, prefix_part, 10) catch return false;

        // IPv4 prefix: 0-32, IPv6: 0-128
        if (std.mem.indexOfScalar(u8, ip_part, '.') != null) {
            return prefix <= 32;
        } else {
            return prefix <= 128;
        }
    }

    return isValidIp(str);
}

fn isValidInterfaceAttribute(name: []const u8) bool {
    const valid = [_][]const u8{ "state", "mtu", "address", "master", "mode" };
    for (valid) |v| {
        if (std.mem.eql(u8, name, v)) return true;
    }
    return false;
}

fn isValidRouteAttribute(name: []const u8) bool {
    const valid = [_][]const u8{ "via", "dev", "metric", "table", "proto", "scope" };
    for (valid) |v| {
        if (std.mem.eql(u8, name, v)) return true;
    }
    return false;
}

fn isValidBondMode(mode: []const u8) bool {
    const valid = [_][]const u8{
        "balance-rr",
        "active-backup",
        "balance-xor",
        "broadcast",
        "802.3ad",
        "balance-tlb",
        "balance-alb",
        "0",
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
    };
    for (valid) |v| {
        if (std.mem.eql(u8, mode, v)) return true;
    }
    return false;
}

/// Convenience function to validate a command
pub fn validateCommand(cmd: *const Command, allocator: std.mem.Allocator) SemanticError!ValidationResult {
    var validator = Validator.init(allocator);
    defer validator.deinit();

    try validator.validate(cmd);
    return validator.result();
}

// Tests

test "validate interface show requires name" {
    const allocator = std.testing.allocator;
    const cmd = Command{
        .subject = .{ .interface = .{ .name = null } },
        .action = .{ .show = {} },
        .attributes = &[_]Attribute{},
    };

    const result = validateCommand(&cmd, allocator) catch |err| {
        try std.testing.expect(err == SemanticError.MissingInterfaceName);
        return;
    };
    var r = result;
    defer r.deinit(allocator);

    try std.testing.expect(!result.valid);
}

test "validate interface show with name is valid" {
    const allocator = std.testing.allocator;
    const cmd = Command{
        .subject = .{ .interface = .{ .name = "eth0" } },
        .action = .{ .show = {} },
        .attributes = &[_]Attribute{},
    };

    var result = try validateCommand(&cmd, allocator);
    defer result.deinit(allocator);

    try std.testing.expect(result.valid);
}

test "validate interface list without name is valid" {
    const allocator = std.testing.allocator;
    const cmd = Command{
        .subject = .{ .interface = .{ .name = null } },
        .action = .{ .none = {} },
        .attributes = &[_]Attribute{},
    };

    var result = try validateCommand(&cmd, allocator);
    defer result.deinit(allocator);

    try std.testing.expect(result.valid);
}

test "validate invalid mtu" {
    const allocator = std.testing.allocator;
    const cmd = Command{
        .subject = .{ .interface = .{ .name = "eth0" } },
        .action = .{ .set = .{ .attr = "mtu", .value = "50" } },
        .attributes = &[_]Attribute{},
    };

    const result = validateCommand(&cmd, allocator) catch |err| {
        try std.testing.expect(err == SemanticError.InvalidMtu);
        return;
    };
    var r = result;
    defer r.deinit(allocator);
}

test "validate valid mtu" {
    const allocator = std.testing.allocator;
    const cmd = Command{
        .subject = .{ .interface = .{ .name = "eth0" } },
        .action = .{ .set = .{ .attr = "mtu", .value = "9000" } },
        .attributes = &[_]Attribute{},
    };

    var result = try validateCommand(&cmd, allocator);
    defer result.deinit(allocator);

    try std.testing.expect(result.valid);
}

test "validate route add requires gateway" {
    const allocator = std.testing.allocator;
    const cmd = Command{
        .subject = .{ .route = .{ .destination = null } },
        .action = .{ .add = .{ .value = "default" } },
        .attributes = &[_]Attribute{},
    };

    const result = validateCommand(&cmd, allocator) catch |err| {
        try std.testing.expect(err == SemanticError.MissingGateway);
        return;
    };
    var r = result;
    defer r.deinit(allocator);
}

test "validate route add with gateway is valid" {
    const allocator = std.testing.allocator;
    const attrs = [_]Attribute{
        .{ .name = "via", .value = "10.0.0.254" },
    };
    const cmd = Command{
        .subject = .{ .route = .{ .destination = null } },
        .action = .{ .add = .{ .value = "default" } },
        .attributes = &attrs,
    };

    var result = try validateCommand(&cmd, allocator);
    defer result.deinit(allocator);

    try std.testing.expect(result.valid);
}
