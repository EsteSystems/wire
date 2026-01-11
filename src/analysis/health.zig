const std = @import("std");
const state_types = @import("../state/types.zig");

/// Health check result
pub const HealthCheck = struct {
    status: Status,
    category: Category,
    message: [128]u8,
    message_len: usize,
    recommendation: [256]u8,
    recommendation_len: usize,

    pub const Status = enum {
        healthy,
        degraded,
        unhealthy,

        pub fn symbol(self: Status) []const u8 {
            return switch (self) {
                .healthy => "[ok]",
                .degraded => "[warn]",
                .unhealthy => "[err]",
            };
        }
    };

    pub const Category = enum {
        interface,
        address,
        route,
        bond,
        bridge,
        vlan,
    };

    pub fn getMessage(self: *const HealthCheck) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn getRecommendation(self: *const HealthCheck) ?[]const u8 {
        if (self.recommendation_len == 0) return null;
        return self.recommendation[0..self.recommendation_len];
    }

    pub fn format(self: *const HealthCheck, writer: anytype) !void {
        try writer.print("{s} {s}", .{ self.status.symbol(), self.getMessage() });
        if (self.getRecommendation()) |rec| {
            try writer.print("\n    -> {s}", .{rec});
        }
        try writer.print("\n", .{});
    }
};

/// Health analyzer
pub const HealthAnalyzer = struct {
    allocator: std.mem.Allocator,
    checks: std.ArrayList(HealthCheck),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .checks = std.ArrayList(HealthCheck).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.checks.deinit();
    }

    /// Analyze health of network configuration
    pub fn analyze(self: *Self, state: *const state_types.NetworkState) ![]const HealthCheck {
        self.checks.clearRetainingCapacity();

        // Check interfaces
        try self.checkInterfaces(state);

        // Check bonds
        try self.checkBonds(state);

        // Check bridges
        try self.checkBridges(state);

        // Check VLANs
        try self.checkVlans(state);

        // Check for IP conflicts
        try self.checkAddressConflicts(state);

        // Check routes
        try self.checkRoutes(state);

        return self.checks.items;
    }

    /// Check interface health
    fn checkInterfaces(self: *Self, state: *const state_types.NetworkState) !void {
        var total: usize = 0;
        var up: usize = 0;
        var with_address: usize = 0;

        for (state.interfaces.items) |*iface| {
            if (iface.link_type == .loopback) continue;
            total += 1;

            if (iface.isUp()) {
                up += 1;

                // Check if it has an address
                const addrs = state.getAddressesForInterface(iface.index);
                if (addrs.len > 0) {
                    with_address += 1;
                }
            }
        }

        if (total == 0) {
            try self.addCheck(.unhealthy, .interface, "No network interfaces found", null);
        } else if (up == 0) {
            try self.addCheckFmt(.unhealthy, .interface, "{d} interfaces found, none are up", .{total}, "Bring up at least one interface");
        } else {
            try self.addCheckFmt(.healthy, .interface, "{d} interfaces configured ({d} up)", .{ total, up }, null);
        }
    }

    /// Check bond health
    fn checkBonds(self: *Self, state: *const state_types.NetworkState) !void {
        for (state.bonds.items) |*bond| {
            const member_count = bond.members.items.len;

            if (member_count == 0) {
                try self.addCheckFmt(
                    .degraded,
                    .bond,
                    "Bond '{s}' has no members",
                    .{bond.getName()},
                    "Add members for redundancy",
                );
            } else if (member_count == 1) {
                try self.addCheckFmt(
                    .degraded,
                    .bond,
                    "Bond '{s}' has only 1 member",
                    .{bond.getName()},
                    "Add at least one more member for redundancy",
                );
            } else {
                // Check member status
                var active_members: usize = 0;
                for (bond.members.items) |member_idx| {
                    if (state.findInterfaceByIndex(member_idx)) |member| {
                        if (member.isUp() and member.hasCarrier()) {
                            active_members += 1;
                        }
                    }
                }

                if (active_members == 0) {
                    try self.addCheckFmt(
                        .unhealthy,
                        .bond,
                        "Bond '{s}' has no active members",
                        .{bond.getName()},
                        "Check member interface status and cable connections",
                    );
                } else if (active_members < member_count) {
                    try self.addCheckFmt(
                        .degraded,
                        .bond,
                        "Bond '{s}' running degraded ({d}/{d} members active)",
                        .{ bond.getName(), active_members, member_count },
                        "Check inactive member interfaces",
                    );
                } else {
                    try self.addCheckFmt(.healthy, .bond, "Bond '{s}' healthy ({d} members)", .{ bond.getName(), member_count }, null);
                }
            }
        }
    }

    /// Check bridge health
    fn checkBridges(self: *Self, state: *const state_types.NetworkState) !void {
        for (state.bridges.items) |*bridge| {
            const port_count = bridge.ports.items.len;

            if (port_count == 0) {
                try self.addCheckFmt(
                    .degraded,
                    .bridge,
                    "Bridge '{s}' has no ports",
                    .{bridge.getName()},
                    "Add ports to enable bridging",
                );
            } else {
                try self.addCheckFmt(.healthy, .bridge, "Bridge '{s}' has {d} port(s)", .{ bridge.getName(), port_count }, null);
            }
        }
    }

    /// Check VLAN health
    fn checkVlans(self: *Self, state: *const state_types.NetworkState) !void {
        for (state.vlans.items) |*vlan| {
            // Check if parent exists
            if (state.findInterfaceByIndex(vlan.parent_index)) |parent| {
                if (!parent.isUp()) {
                    try self.addCheckFmt(
                        .degraded,
                        .vlan,
                        "VLAN '{s}' parent interface is down",
                        .{vlan.getName()},
                        "Bring up the parent interface",
                    );
                } else {
                    try self.addCheckFmt(.healthy, .vlan, "VLAN '{s}' (ID {d}) on parent index {d}", .{ vlan.getName(), vlan.vlan_id, vlan.parent_index }, null);
                }
            } else {
                try self.addCheckFmt(
                    .unhealthy,
                    .vlan,
                    "VLAN '{s}' parent interface not found",
                    .{vlan.getName()},
                    "Check parent interface exists",
                );
            }
        }
    }

    /// Check for address conflicts
    fn checkAddressConflicts(self: *Self, state: *const state_types.NetworkState) !void {
        // Check for duplicate IPv4 addresses
        var seen = std.AutoHashMap([4]u8, []const u8).init(self.allocator);
        defer seen.deinit();

        for (state.addresses.items) |*addr| {
            if (addr.family != 2) continue; // IPv4 only

            const ip = addr.address[0..4].*;
            const iface_name = blk: {
                if (state.findInterfaceByIndex(addr.interface_index)) |iface| {
                    break :blk iface.getName();
                }
                break :blk "unknown";
            };

            if (seen.get(ip)) |existing| {
                try self.addCheckFmt(
                    .unhealthy,
                    .address,
                    "IP {d}.{d}.{d}.{d} assigned to multiple interfaces",
                    .{ ip[0], ip[1], ip[2], ip[3] },
                    "Remove duplicate address",
                );
                _ = existing;
            } else {
                try seen.put(ip, iface_name);
            }
        }
    }

    /// Check route health
    fn checkRoutes(self: *Self, state: *const state_types.NetworkState) !void {
        var unicast_count: usize = 0;
        var default_count: usize = 0;

        for (state.routes.items) |*route| {
            if (route.route_type != 1) continue; // unicast only
            unicast_count += 1;

            if (route.dst_len == 0) {
                default_count += 1;
            }
        }

        if (default_count > 1) {
            try self.addCheckFmt(
                .degraded,
                .route,
                "Multiple default routes configured ({d})",
                .{default_count},
                "Consider using only one default route for predictable behavior",
            );
        } else if (unicast_count > 0) {
            try self.addCheckFmt(.healthy, .route, "{d} routes configured", .{unicast_count}, null);
        }
    }

    /// Add a health check
    fn addCheck(self: *Self, status: HealthCheck.Status, category: HealthCheck.Category, message: []const u8, recommendation: ?[]const u8) !void {
        var check = HealthCheck{
            .status = status,
            .category = category,
            .message = undefined,
            .message_len = 0,
            .recommendation = undefined,
            .recommendation_len = 0,
        };

        const msg_len = @min(message.len, check.message.len);
        @memcpy(check.message[0..msg_len], message[0..msg_len]);
        check.message_len = msg_len;

        if (recommendation) |rec| {
            const rec_len = @min(rec.len, check.recommendation.len);
            @memcpy(check.recommendation[0..rec_len], rec[0..rec_len]);
            check.recommendation_len = rec_len;
        }

        try self.checks.append(check);
    }

    /// Add a health check with formatted message
    fn addCheckFmt(
        self: *Self,
        status: HealthCheck.Status,
        category: HealthCheck.Category,
        comptime msg_fmt: []const u8,
        msg_args: anytype,
        recommendation: ?[]const u8,
    ) !void {
        var check = HealthCheck{
            .status = status,
            .category = category,
            .message = undefined,
            .message_len = 0,
            .recommendation = undefined,
            .recommendation_len = 0,
        };

        const msg = std.fmt.bufPrint(&check.message, msg_fmt, msg_args) catch {
            check.message_len = check.message.len;
            return try self.checks.append(check);
        };
        check.message_len = msg.len;

        if (recommendation) |rec| {
            const rec_len = @min(rec.len, check.recommendation.len);
            @memcpy(check.recommendation[0..rec_len], rec[0..rec_len]);
            check.recommendation_len = rec_len;
        }

        try self.checks.append(check);
    }

    /// Format all checks
    pub fn format(self: *const Self, writer: anytype) !void {
        try writer.print("Configuration Health\n", .{});
        try writer.print("--------------------\n", .{});

        for (self.checks.items) |*check| {
            try check.format(writer);
        }
    }

    /// Get overall health status
    pub fn overallStatus(self: *const Self) HealthCheck.Status {
        var worst = HealthCheck.Status.healthy;

        for (self.checks.items) |*check| {
            switch (check.status) {
                .unhealthy => return .unhealthy,
                .degraded => worst = .degraded,
                .healthy => {},
            }
        }

        return worst;
    }

    /// Status counts
    pub const StatusCounts = struct {
        healthy: usize,
        degraded: usize,
        unhealthy: usize,
    };

    /// Count checks by status
    pub fn countByStatus(self: *const Self) StatusCounts {
        var counts = StatusCounts{ .healthy = 0, .degraded = 0, .unhealthy = 0 };

        for (self.checks.items) |*check| {
            switch (check.status) {
                .healthy => counts.healthy += 1,
                .degraded => counts.degraded += 1,
                .unhealthy => counts.unhealthy += 1,
            }
        }

        return counts;
    }
};

// Tests

test "HealthAnalyzer init" {
    const allocator = std.testing.allocator;
    var analyzer = HealthAnalyzer.init(allocator);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.checks.items.len == 0);
}
