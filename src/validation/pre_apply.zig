const std = @import("std");
const parser = @import("../syntax/parser.zig");
const state_types = @import("../state/types.zig");
const state_live = @import("../state/live.zig");
const checks = @import("checks.zig");

/// Validation issue severity
pub const Severity = enum {
    err, // Will definitely fail
    warning, // May cause problems
    info, // Informational

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .err => "ERROR",
            .warning => "WARNING",
            .info => "INFO",
        };
    }

    pub fn symbol(self: Severity) []const u8 {
        return switch (self) {
            .err => "[!]",
            .warning => "[?]",
            .info => "[i]",
        };
    }
};

/// Validation issue codes
pub const ValidationCode = enum {
    // Interface issues
    interface_not_found,
    interface_already_exists,
    interface_is_loopback,

    // Gateway/routing issues
    gateway_unreachable,
    gateway_not_in_subnet,
    no_route_to_gateway,

    // Address issues
    address_conflict,
    address_already_assigned,
    address_on_down_interface,

    // Route issues
    route_conflict,
    route_duplicate,
    route_unreachable_gateway,

    // Dependency issues
    dependency_missing,
    parent_interface_missing,
    bond_member_missing,
    bridge_port_missing,

    // Dangerous operations
    removing_default_route,
    removing_only_address,
    bringing_down_management_interface,

    // General
    unknown_error,
};

/// A validation issue found during pre-apply validation
pub const ValidationIssue = struct {
    severity: Severity,
    code: ValidationCode,
    message: [256]u8,
    message_len: usize,
    suggestion: [256]u8,
    suggestion_len: usize,
    command_index: ?usize,

    pub fn getMessage(self: *const ValidationIssue) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn getSuggestion(self: *const ValidationIssue) ?[]const u8 {
        if (self.suggestion_len == 0) return null;
        return self.suggestion[0..self.suggestion_len];
    }

    pub fn format(self: *const ValidationIssue, writer: anytype) !void {
        try writer.print("{s} {s}", .{ self.severity.symbol(), self.getMessage() });
        if (self.getSuggestion()) |sug| {
            try writer.print("\n    Suggestion: {s}", .{sug});
        }
        try writer.print("\n", .{});
    }
};

/// Result of pre-apply validation
pub const ValidationReport = struct {
    issues: std.ArrayList(ValidationIssue),
    errors: usize,
    warnings: usize,
    infos: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .issues = std.ArrayList(ValidationIssue).init(allocator),
            .errors = 0,
            .warnings = 0,
            .infos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.issues.deinit();
    }

    pub fn hasErrors(self: *const Self) bool {
        return self.errors > 0;
    }

    pub fn hasWarnings(self: *const Self) bool {
        return self.warnings > 0;
    }

    pub fn addIssue(self: *Self, issue: ValidationIssue) !void {
        switch (issue.severity) {
            .err => self.errors += 1,
            .warning => self.warnings += 1,
            .info => self.infos += 1,
        }
        try self.issues.append(issue);
    }

    pub fn format(self: *const Self, writer: anytype) !void {
        if (self.issues.items.len == 0) {
            try writer.print("Pre-apply validation: OK (no issues found)\n", .{});
            return;
        }

        try writer.print("Pre-apply Validation Report\n", .{});
        try writer.print("===========================\n\n", .{});

        // Group by severity
        if (self.errors > 0) {
            try writer.print("Errors ({d}):\n", .{self.errors});
            for (self.issues.items) |*issue| {
                if (issue.severity == .err) {
                    try issue.format(writer);
                }
            }
            try writer.print("\n", .{});
        }

        if (self.warnings > 0) {
            try writer.print("Warnings ({d}):\n", .{self.warnings});
            for (self.issues.items) |*issue| {
                if (issue.severity == .warning) {
                    try issue.format(writer);
                }
            }
            try writer.print("\n", .{});
        }

        if (self.infos > 0) {
            try writer.print("Info ({d}):\n", .{self.infos});
            for (self.issues.items) |*issue| {
                if (issue.severity == .info) {
                    try issue.format(writer);
                }
            }
            try writer.print("\n", .{});
        }

        try writer.print("Summary: {d} error(s), {d} warning(s), {d} info(s)\n", .{ self.errors, self.warnings, self.infos });
    }
};

/// Tracks what interfaces/resources will be created by pending commands
pub const PendingCreates = struct {
    interfaces: std.StringHashMap(void),
    bonds: std.StringHashMap(void),
    bridges: std.StringHashMap(void),
    vlans: std.StringHashMap(void),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .interfaces = std.StringHashMap(void).init(allocator),
            .bonds = std.StringHashMap(void).init(allocator),
            .bridges = std.StringHashMap(void).init(allocator),
            .vlans = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.interfaces.deinit();
        self.bonds.deinit();
        self.bridges.deinit();
        self.vlans.deinit();
    }

    pub fn willExist(self: *const Self, name: []const u8) bool {
        return self.interfaces.contains(name) or
            self.bonds.contains(name) or
            self.bridges.contains(name) or
            self.vlans.contains(name);
    }
};

/// Pre-apply validator - validates commands against live network state
pub const PreApplyValidator = struct {
    allocator: std.mem.Allocator,
    live_state: state_types.NetworkState,
    pending: PendingCreates,
    report: ValidationReport,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Query current live state
        const live = try state_live.queryLiveState(allocator);

        return Self{
            .allocator = allocator,
            .live_state = live,
            .pending = PendingCreates.init(allocator),
            .report = ValidationReport.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.live_state.deinit();
        self.pending.deinit();
        self.report.deinit();
    }

    /// Validate a list of commands before applying
    pub fn validate(self: *Self, commands: []const parser.Command) !*ValidationReport {
        // First pass: identify what will be created
        for (commands) |*cmd| {
            self.trackCreates(cmd);
        }

        // Second pass: validate each command
        for (commands, 0..) |*cmd, i| {
            try self.validateCommand(cmd, i);
        }

        return &self.report;
    }

    /// Track resources that will be created by a command
    fn trackCreates(self: *Self, cmd: *const parser.Command) void {
        switch (cmd.subject) {
            .bond => |b| {
                if (b.name) |name| {
                    switch (cmd.action) {
                        .create => {
                            self.pending.bonds.put(name, {}) catch {};
                            self.pending.interfaces.put(name, {}) catch {};
                        },
                        else => {},
                    }
                }
            },
            .bridge => |b| {
                if (b.name) |name| {
                    switch (cmd.action) {
                        .create => {
                            self.pending.bridges.put(name, {}) catch {};
                            self.pending.interfaces.put(name, {}) catch {};
                        },
                        else => {},
                    }
                }
            },
            .vlan => |v| {
                if (v.parent) |parent| {
                    if (v.id) |id| {
                        var name_buf: [32]u8 = undefined;
                        const vlan_name = std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ parent, id }) catch return;
                        self.pending.vlans.put(vlan_name, {}) catch {};
                        self.pending.interfaces.put(vlan_name, {}) catch {};
                    }
                }
            },
            else => {},
        }
    }

    /// Validate a single command
    fn validateCommand(self: *Self, cmd: *const parser.Command, index: usize) !void {
        switch (cmd.subject) {
            .interface => |iface| try self.validateInterfaceCommand(iface, cmd.action, cmd.attributes, index),
            .route => |route| try self.validateRouteCommand(route, cmd.action, cmd.attributes, index),
            .bond => |bond| try self.validateBondCommand(bond, cmd.action, cmd.attributes, index),
            .bridge => |bridge| try self.validateBridgeCommand(bridge, cmd.action, cmd.attributes, index),
            .vlan => |vlan| try self.validateVlanCommand(vlan, index),
            .veth => {}, // Veth creation doesn't need pre-validation
            .analyze => {},
            .tc => {}, // TC commands validated via CLI
            .tunnel => {}, // Tunnel commands validated via CLI
        }
    }

    /// Validate interface commands
    fn validateInterfaceCommand(
        self: *Self,
        iface: parser.InterfaceSubject,
        action: parser.Action,
        attributes: []const parser.Attribute,
        index: usize,
    ) !void {
        _ = attributes;

        const name = iface.name orelse return;

        // Check if interface exists (or will be created)
        if (!self.interfaceExists(name)) {
            try self.report.addIssue(checks.createIssue(
                .err,
                .interface_not_found,
                "Interface '{s}' does not exist",
                .{name},
                "Ensure interface exists or will be created before this command",
                index,
            ));
            return;
        }

        // Check for dangerous operations
        switch (action) {
            .set => |set| {
                if (std.mem.eql(u8, set.attr, "state") and std.mem.eql(u8, set.value, "down")) {
                    // Check if this is the only interface with an address
                    if (self.isOnlyAddressedInterface(name)) {
                        try self.report.addIssue(checks.createIssue(
                            .warning,
                            .bringing_down_management_interface,
                            "Bringing down '{s}' may cause loss of network connectivity",
                            .{name},
                            "Ensure you have alternative access before proceeding",
                            index,
                        ));
                    }
                }
            },
            .del => {
                // Check if removing the only address
                if (self.hasOnlyOneAddress(name)) {
                    try self.report.addIssue(checks.createIssue(
                        .warning,
                        .removing_only_address,
                        "Removing the only address from '{s}' may cause connectivity loss",
                        .{name},
                        "Ensure you have alternative access",
                        index,
                    ));
                }
            },
            else => {},
        }
    }

    /// Validate route commands
    fn validateRouteCommand(
        self: *Self,
        route: parser.RouteSubject,
        action: parser.Action,
        attributes: []const parser.Attribute,
        index: usize,
    ) !void {
        switch (action) {
            .add => |add| {
                const dest = route.destination orelse add.value;

                // Check gateway reachability
                for (attributes) |attr| {
                    if (std.mem.eql(u8, attr.name, "via")) {
                        if (attr.value) |gw| {
                            if (!self.isGatewayReachable(gw)) {
                                try self.report.addIssue(checks.createIssue(
                                    .warning,
                                    .gateway_unreachable,
                                    "Gateway '{s}' may not be reachable from any interface",
                                    .{gw},
                                    "Ensure an interface has an address in the same subnet as the gateway",
                                    index,
                                ));
                            }
                        }
                    }
                }

                // Check for route conflicts
                if (dest) |d| {
                    if (self.hasConflictingRoute(d)) {
                        try self.report.addIssue(checks.createIssue(
                            .warning,
                            .route_conflict,
                            "A route for '{s}' already exists",
                            .{d},
                            "The existing route may be replaced",
                            index,
                        ));
                    }
                }
            },
            .del => |del| {
                const dest = route.destination orelse del.value;
                if (dest) |d| {
                    if (std.mem.eql(u8, d, "default")) {
                        try self.report.addIssue(checks.createIssue(
                            .warning,
                            .removing_default_route,
                            "Removing default route may cause loss of external connectivity",
                            .{},
                            "Ensure you have alternative access or a new default route will be added",
                            index,
                        ));
                    }
                }
            },
            else => {},
        }
    }

    /// Validate bond commands
    fn validateBondCommand(
        self: *Self,
        bond: parser.BondSubject,
        action: parser.Action,
        attributes: []const parser.Attribute,
        index: usize,
    ) !void {
        _ = attributes;
        const name = bond.name orelse return;

        switch (action) {
            .create => {
                // Check if bond already exists
                if (self.interfaceExists(name)) {
                    try self.report.addIssue(checks.createIssue(
                        .err,
                        .interface_already_exists,
                        "Interface '{s}' already exists",
                        .{name},
                        "Choose a different name or delete the existing interface first",
                        index,
                    ));
                }
            },
            .add => |add| {
                // Check if bond exists (or will be created)
                if (!self.interfaceExists(name) and !self.pending.bonds.contains(name)) {
                    try self.report.addIssue(checks.createIssue(
                        .err,
                        .dependency_missing,
                        "Bond '{s}' does not exist",
                        .{name},
                        "Create the bond before adding members",
                        index,
                    ));
                }

                // Check if member exists
                if (add.value) |member| {
                    if (!self.interfaceExists(member)) {
                        try self.report.addIssue(checks.createIssue(
                            .err,
                            .bond_member_missing,
                            "Interface '{s}' does not exist (cannot add to bond)",
                            .{member},
                            "Ensure the member interface exists",
                            index,
                        ));
                    }
                }
            },
            else => {},
        }
    }

    /// Validate bridge commands
    fn validateBridgeCommand(
        self: *Self,
        bridge: parser.BridgeSubject,
        action: parser.Action,
        attributes: []const parser.Attribute,
        index: usize,
    ) !void {
        _ = attributes;
        const name = bridge.name orelse return;

        switch (action) {
            .create => {
                if (self.interfaceExists(name)) {
                    try self.report.addIssue(checks.createIssue(
                        .err,
                        .interface_already_exists,
                        "Interface '{s}' already exists",
                        .{name},
                        "Choose a different name or delete the existing interface first",
                        index,
                    ));
                }
            },
            .add => |add| {
                if (!self.interfaceExists(name) and !self.pending.bridges.contains(name)) {
                    try self.report.addIssue(checks.createIssue(
                        .err,
                        .dependency_missing,
                        "Bridge '{s}' does not exist",
                        .{name},
                        "Create the bridge before adding ports",
                        index,
                    ));
                }

                if (add.value) |port| {
                    if (!self.interfaceExists(port)) {
                        try self.report.addIssue(checks.createIssue(
                            .err,
                            .bridge_port_missing,
                            "Interface '{s}' does not exist (cannot add to bridge)",
                            .{port},
                            "Ensure the port interface exists",
                            index,
                        ));
                    }
                }
            },
            else => {},
        }
    }

    /// Validate VLAN commands
    fn validateVlanCommand(
        self: *Self,
        vlan: parser.VlanSubject,
        index: usize,
    ) !void {
        if (vlan.parent) |parent| {
            if (!self.interfaceExists(parent) and !self.pending.willExist(parent)) {
                try self.report.addIssue(checks.createIssue(
                    .err,
                    .parent_interface_missing,
                    "Parent interface '{s}' does not exist",
                    .{parent},
                    "Ensure the parent interface exists before creating the VLAN",
                    index,
                ));
            }
        }
    }

    // Helper functions

    fn interfaceExists(self: *const Self, name: []const u8) bool {
        // Check live state
        if (self.live_state.findInterface(name) != null) return true;

        // Check pending creates
        return self.pending.willExist(name);
    }

    fn isOnlyAddressedInterface(self: *const Self, name: []const u8) bool {
        var addressed_count: usize = 0;
        var is_addressed = false;

        for (self.live_state.interfaces.items) |*iface| {
            const addrs = self.live_state.getAddressesForInterface(iface.index);
            if (addrs.len > 0) {
                addressed_count += 1;
                if (std.mem.eql(u8, iface.getName(), name)) {
                    is_addressed = true;
                }
            }
        }

        return is_addressed and addressed_count == 1;
    }

    fn hasOnlyOneAddress(self: *const Self, name: []const u8) bool {
        const iface = self.live_state.findInterface(name) orelse return false;
        const addrs = self.live_state.getAddressesForInterface(iface.index);
        return addrs.len == 1;
    }

    fn isGatewayReachable(self: *const Self, gateway_str: []const u8) bool {
        // Parse gateway IP
        const gw = parseIPv4(gateway_str) orelse return false;

        // Check if gateway is in any interface's subnet
        for (self.live_state.addresses.items) |*addr| {
            if (addr.family != 2) continue; // IPv4 only for now

            if (isInSubnet(gw, addr.address[0..4].*, addr.prefix_len)) {
                return true;
            }
        }

        // Check if there's an existing route to the gateway
        for (self.live_state.routes.items) |*route| {
            if (route.family != 2) continue;
            if (route.route_type != 1) continue; // unicast only

            if (route.dst_len == 0) {
                // Default route - gateway is reachable if we have a default
                return true;
            }

            // Check if gateway is in route's destination
            if (isInSubnet(gw, route.dst[0..4].*, route.dst_len)) {
                return true;
            }
        }

        return false;
    }

    fn hasConflictingRoute(self: *const Self, dest_str: []const u8) bool {
        if (std.mem.eql(u8, dest_str, "default")) {
            // Check for existing default route
            for (self.live_state.routes.items) |*route| {
                if (route.dst_len == 0 and route.route_type == 1) {
                    return true;
                }
            }
            return false;
        }

        // Parse destination
        const parsed = parseIPv4CIDR(dest_str) orelse return false;

        for (self.live_state.routes.items) |*route| {
            if (route.family != 2) continue;
            if (route.route_type != 1) continue;
            if (route.dst_len != parsed.prefix) continue;

            if (std.mem.eql(u8, route.dst[0..4], &parsed.addr)) {
                return true;
            }
        }

        return false;
    }
};

// IP parsing helpers

fn parseIPv4(str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octets: usize = 0;
    var current: u16 = 0;
    var start: usize = 0;

    for (str, 0..) |c, i| {
        if (c == '.' or c == '/') {
            if (octets >= 4) return null;
            const octet = std.fmt.parseInt(u8, str[start..i], 10) catch return null;
            result[octets] = octet;
            octets += 1;
            start = i + 1;
            if (c == '/') break;
        }
        current = current;
    }

    if (octets < 4 and start < str.len) {
        // Parse last octet
        var end = str.len;
        for (str[start..], 0..) |c, j| {
            if (c == '/') {
                end = start + j;
                break;
            }
        }
        const octet = std.fmt.parseInt(u8, str[start..end], 10) catch return null;
        result[octets] = octet;
        octets += 1;
    }

    if (octets != 4) return null;
    return result;
}

const ParsedIPv4 = struct {
    addr: [4]u8,
    prefix: u8,
};

fn parseIPv4CIDR(str: []const u8) ?ParsedIPv4 {
    const addr = parseIPv4(str) orelse return null;

    // Find prefix
    if (std.mem.indexOfScalar(u8, str, '/')) |slash| {
        const prefix = std.fmt.parseInt(u8, str[slash + 1 ..], 10) catch return null;
        return ParsedIPv4{ .addr = addr, .prefix = prefix };
    }

    return ParsedIPv4{ .addr = addr, .prefix = 32 };
}

fn isInSubnet(ip: [4]u8, network: [4]u8, prefix_len: u8) bool {
    if (prefix_len == 0) return true;
    if (prefix_len > 32) return false;

    const mask = if (prefix_len == 32) @as(u32, 0xFFFFFFFF) else (~@as(u32, 0)) << @intCast(32 - prefix_len);

    const ip_u32 = (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | @as(u32, ip[3]);
    const net_u32 = (@as(u32, network[0]) << 24) | (@as(u32, network[1]) << 16) | (@as(u32, network[2]) << 8) | @as(u32, network[3]);

    return (ip_u32 & mask) == (net_u32 & mask);
}

/// Convenience function to validate commands before applying
pub fn validateBeforeApply(commands: []const parser.Command, allocator: std.mem.Allocator) !ValidationReport {
    var validator = try PreApplyValidator.init(allocator);
    defer validator.deinit();

    _ = try validator.validate(commands);

    // Copy report to return (since validator will be deinitialized)
    var result = ValidationReport.init(allocator);
    result.errors = validator.report.errors;
    result.warnings = validator.report.warnings;
    result.infos = validator.report.infos;

    for (validator.report.issues.items) |issue| {
        try result.issues.append(issue);
    }

    return result;
}

// Tests

test "PreApplyValidator init" {
    // This test requires a real system, so we'll just test the types
    const allocator = std.testing.allocator;
    var report = ValidationReport.init(allocator);
    defer report.deinit();

    try std.testing.expect(!report.hasErrors());
}

test "isInSubnet" {
    // 10.0.0.1 in 10.0.0.0/24
    try std.testing.expect(isInSubnet(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 0 }, 24));

    // 10.0.1.1 not in 10.0.0.0/24
    try std.testing.expect(!isInSubnet(.{ 10, 0, 1, 1 }, .{ 10, 0, 0, 0 }, 24));

    // 192.168.1.100 in 192.168.0.0/16
    try std.testing.expect(isInSubnet(.{ 192, 168, 1, 100 }, .{ 192, 168, 0, 0 }, 16));

    // Default route matches all
    try std.testing.expect(isInSubnet(.{ 8, 8, 8, 8 }, .{ 0, 0, 0, 0 }, 0));
}

test "parseIPv4" {
    const ip = parseIPv4("10.0.0.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 1 }, ip.?);

    const ip2 = parseIPv4("192.168.1.100/24");
    try std.testing.expect(ip2 != null);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 100 }, ip2.?);
}
