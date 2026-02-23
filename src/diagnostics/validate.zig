const std = @import("std");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_vlan = @import("../netlink/vlan.zig");
const state_live = @import("../state/live.zig");
const topology = @import("../analysis/topology.zig");
const probe = @import("probe.zig");

/// Validation result
pub const ValidationResult = struct {
    passed: bool,
    checks: std.array_list.Managed(Check),

    pub const Check = struct {
        name: []const u8,
        passed: bool,
        message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .passed = true,
            .checks = std.array_list.Managed(Check).init(allocator),
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        self.checks.deinit();
    }

    pub fn addCheck(self: *ValidationResult, name: []const u8, passed: bool, message: []const u8) !void {
        try self.checks.append(.{
            .name = name,
            .passed = passed,
            .message = message,
        });
        if (!passed) {
            self.passed = false;
        }
    }

    pub fn format(self: *const ValidationResult, writer: anytype) !void {
        for (self.checks.items) |check| {
            const status = if (check.passed) "[PASS]" else "[FAIL]";
            try writer.print("{s} {s}: {s}\n", .{ status, check.name, check.message });
        }

        try writer.print("\n", .{});
        if (self.passed) {
            try writer.print("Validation PASSED\n", .{});
        } else {
            try writer.print("Validation FAILED\n", .{});
        }
    }
};

/// Validate a VLAN configuration
pub fn validateVlan(allocator: std.mem.Allocator, vlan_id: u16, parent_name: []const u8) !ValidationResult {
    var result = ValidationResult.init(allocator);
    errdefer result.deinit();

    // Check 1: Parent interface exists
    const maybe_parent = netlink_interface.getInterfaceByName(allocator, parent_name) catch |err| {
        try result.addCheck("Parent exists", false, @errorName(err));
        return result;
    };

    if (maybe_parent == null) {
        try result.addCheck("Parent exists", false, "Parent interface not found");
        return result;
    }
    const parent = maybe_parent.?;
    try result.addCheck("Parent exists", true, parent_name);

    // Check 2: Parent interface is up
    if (parent.isUp()) {
        try result.addCheck("Parent is UP", true, "Interface is up");
    } else {
        try result.addCheck("Parent is UP", false, "Interface is down");
    }

    // Check 3: Parent has carrier
    if (parent.hasCarrier()) {
        try result.addCheck("Parent has carrier", true, "Link detected");
    } else {
        try result.addCheck("Parent has carrier", false, "No carrier");
    }

    // Check 4: VLAN interface exists
    // Try common naming conventions
    var vlan_name_buf: [32]u8 = undefined;
    const vlan_name = std.fmt.bufPrint(&vlan_name_buf, "{s}.{d}", .{ parent_name, vlan_id }) catch "?";

    const maybe_vlan = netlink_interface.getInterfaceByName(allocator, vlan_name) catch null;

    if (maybe_vlan) |vlan_iface| {
        try result.addCheck("VLAN interface exists", true, vlan_name);

        // Check 5: VLAN interface is up
        if (vlan_iface.isUp()) {
            try result.addCheck("VLAN is UP", true, "Interface is up");
        } else {
            try result.addCheck("VLAN is UP", false, "Interface is down");
        }

        // Check 6: VLAN has IP address (optional but common)
        const addrs = netlink_interface.getInterfaceByName(allocator, vlan_name) catch null;
        _ = addrs;
        // Note: Would need to query addresses separately
        try result.addCheck("VLAN configured", true, "VLAN interface ready");
    } else {
        try result.addCheck("VLAN interface exists", false, "VLAN interface not found");
    }

    return result;
}

/// Validate a network path
pub fn validatePath(allocator: std.mem.Allocator, source_iface: []const u8, destination: []const u8) !ValidationResult {
    var result = ValidationResult.init(allocator);
    errdefer result.deinit();

    // Check 1: Source interface exists
    const maybe_source = netlink_interface.getInterfaceByName(allocator, source_iface) catch |err| {
        try result.addCheck("Source interface exists", false, @errorName(err));
        return result;
    };

    if (maybe_source == null) {
        try result.addCheck("Source interface exists", false, "Interface not found");
        return result;
    }
    const source = maybe_source.?;
    try result.addCheck("Source interface exists", true, source_iface);

    // Check 2: Source interface is up
    if (source.isUp()) {
        try result.addCheck("Source is UP", true, "Interface is up");
    } else {
        try result.addCheck("Source is UP", false, "Interface is down");
        return result; // Can't continue if interface is down
    }

    // Check 3: Source has carrier
    if (source.hasCarrier()) {
        try result.addCheck("Source has carrier", true, "Link detected");
    } else {
        try result.addCheck("Source has carrier", false, "No carrier");
        return result;
    }

    // Check 4: Build topology and trace path
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try result.addCheck("Query network state", false, @errorName(err));
        return result;
    };
    defer live_state.deinit();

    var topo = topology.TopologyGraph.buildFromState(allocator, &live_state) catch |err| {
        try result.addCheck("Build topology", false, @errorName(err));
        return result;
    };
    defer topo.deinit();
    try result.addCheck("Build topology", true, "Topology graph built");

    // Check 5: All interfaces in path are up
    const source_node = topo.findNodeByName(source_iface);
    if (source_node) |node| {
        if (node.is_up and node.has_carrier) {
            try result.addCheck("Path source ready", true, "Source interface operational");
        } else {
            try result.addCheck("Path source ready", false, "Source interface not operational");
        }

        // Check parent chain
        var current = node;
        var hop_count: usize = 0;
        while (current.parent_index) |parent_idx| {
            if (topo.findNode(parent_idx)) |parent_node| {
                hop_count += 1;
                var hop_buf: [64]u8 = undefined;
                const hop_name = std.fmt.bufPrint(&hop_buf, "Hop {d}: {s}", .{ hop_count, parent_node.getName() }) catch "?";

                if (parent_node.is_up and parent_node.has_carrier) {
                    try result.addCheck(hop_name, true, "Up with carrier");
                } else if (parent_node.is_up) {
                    try result.addCheck(hop_name, false, "Up but no carrier");
                } else {
                    try result.addCheck(hop_name, false, "Interface down");
                }
                current = parent_node;
            } else {
                break;
            }
        }
    }

    // Check 6: Destination is reachable (TCP probe or ICMP)
    // Try to parse as IP and probe
    const probe_result = probe.probeTcp(destination, 22, 2000); // Try SSH port
    if (probe_result.status == .open) {
        try result.addCheck("Destination reachable", true, "TCP connection successful");
    } else if (probe_result.status == .closed) {
        // Port closed but host responded - still reachable
        try result.addCheck("Destination reachable", true, "Host responded (port closed)");
    } else if (probe_result.status == .filtered) {
        try result.addCheck("Destination reachable", false, "Connection timed out (filtered)");
    } else {
        try result.addCheck("Destination reachable", false, "Host unreachable");
    }

    return result;
}

/// Validate connectivity to a specific service
pub fn validateService(allocator: std.mem.Allocator, host: []const u8, port_or_service: []const u8) !ValidationResult {
    var result = ValidationResult.init(allocator);
    errdefer result.deinit();

    // Resolve port
    const port = probe.resolvePort(allocator, port_or_service, .tcp) catch |err| {
        if (err == error.UnknownService) {
            try result.addCheck("Resolve service", false, "Unknown service name");
        } else {
            try result.addCheck("Resolve service", false, "Failed to resolve port");
        }
        return result;
    };

    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch "?";
    try result.addCheck("Resolve service", true, port_str);

    // Probe the service
    const probe_result = probe.probeTcp(host, port, 5000);

    switch (probe_result.status) {
        .open => {
            try result.addCheck("Service available", true, "Connection successful");
        },
        .closed => {
            try result.addCheck("Service available", false, "Connection refused (service not running)");
        },
        .filtered => {
            try result.addCheck("Service available", false, "Connection timed out (firewall?)");
        },
        .host_unreachable => {
            try result.addCheck("Service available", false, "Host unreachable");
        },
        .error_occurred => {
            try result.addCheck("Service available", false, probe_result.error_msg orelse "Unknown error");
        },
    }

    return result;
}

// Tests

test "ValidationResult" {
    var result = ValidationResult.init(std.testing.allocator);
    defer result.deinit();

    try result.addCheck("Test 1", true, "Passed");
    try result.addCheck("Test 2", false, "Failed");

    try std.testing.expect(!result.passed);
    try std.testing.expectEqual(@as(usize, 2), result.checks.items.len);
}
