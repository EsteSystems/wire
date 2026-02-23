const std = @import("std");
const types = @import("types.zig");

/// Export options for selective state export
pub const ExportOptions = struct {
    /// Include interface configurations
    interfaces: bool = true,
    /// Include address configurations
    addresses: bool = true,
    /// Include route configurations
    routes: bool = true,
    /// Include bond configurations
    bonds: bool = true,
    /// Include bridge configurations
    bridges: bool = true,
    /// Include VLAN configurations
    vlans: bool = true,
    /// Include comments with metadata
    comments: bool = true,
    /// Only export interfaces that are UP
    only_up: bool = false,
    /// Skip loopback interface
    skip_loopback: bool = true,
    /// Skip link-local and auto-generated addresses
    skip_auto_addresses: bool = true,
    /// Skip kernel/system routes (proto != RTPROT_STATIC and RTPROT_BOOT)
    skip_kernel_routes: bool = true,

    pub const all = ExportOptions{};

    pub const interfaces_only = ExportOptions{
        .addresses = false,
        .routes = false,
        .bonds = false,
        .bridges = false,
        .vlans = false,
    };

    pub const routes_only = ExportOptions{
        .interfaces = false,
        .addresses = false,
        .bonds = false,
        .bridges = false,
        .vlans = false,
    };

    pub const minimal = ExportOptions{
        .comments = false,
        .skip_loopback = true,
        .skip_auto_addresses = true,
        .skip_kernel_routes = true,
    };

    /// Default export - clean output with comments
    pub const default = ExportOptions{
        .comments = true,
        .skip_loopback = true,
        .skip_auto_addresses = true,
        .skip_kernel_routes = true,
    };
};

/// State exporter - converts NetworkState to wire configuration format
pub const StateExporter = struct {
    allocator: std.mem.Allocator,
    options: ExportOptions,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, options: ExportOptions) Self {
        return Self{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Export state to a writer
    pub fn exportToWriter(self: *Self, state: *const types.NetworkState, writer: anytype) !void {
        if (self.options.comments) {
            try writer.print("# wire network configuration\n", .{});
            try writer.print("# Exported from live state at {d}\n", .{state.timestamp});
            try writer.print("#\n\n", .{});
        }

        // Export bonds first (they need to exist before adding members)
        if (self.options.bonds and state.bonds.items.len > 0) {
            try self.exportBonds(state, writer);
        }

        // Export bridges
        if (self.options.bridges and state.bridges.items.len > 0) {
            try self.exportBridges(state, writer);
        }

        // Export VLANs
        if (self.options.vlans and state.vlans.items.len > 0) {
            try self.exportVlans(state, writer);
        }

        // Export interfaces
        if (self.options.interfaces) {
            try self.exportInterfaces(state, writer);
        }

        // Export addresses
        if (self.options.addresses) {
            try self.exportAddresses(state, writer);
        }

        // Export routes
        if (self.options.routes) {
            try self.exportRoutes(state, writer);
        }
    }

    /// Export to string
    pub fn exportToString(self: *Self, state: *const types.NetworkState) ![]u8 {
        var list = std.array_list.Managed(u8).init(self.allocator);
        errdefer list.deinit();

        try self.exportToWriter(state, list.writer());
        return list.toOwnedSlice();
    }

    /// Export to file
    pub fn exportToFile(self: *Self, state: *const types.NetworkState, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.deprecatedWriter();
        try self.exportToWriter(state, writer);
    }

    fn exportBonds(self: *Self, state: *const types.NetworkState, writer: anytype) !void {
        if (self.options.comments) {
            try writer.print("# Bonds\n", .{});
        }

        for (state.bonds.items) |bond| {
            const name = bond.getName();
            const mode_str = bondModeToString(bond.mode);

            try writer.print("bond {s} create mode {s}\n", .{ name, mode_str });

            // Add members
            for (bond.members.items) |member_index| {
                if (state.findInterfaceByIndex(member_index)) |member| {
                    try writer.print("bond {s} add {s}\n", .{ name, member.getName() });
                }
            }
        }

        try writer.print("\n", .{});
    }

    fn exportBridges(self: *Self, state: *const types.NetworkState, writer: anytype) !void {
        if (self.options.comments) {
            try writer.print("# Bridges\n", .{});
        }

        for (state.bridges.items) |bridge| {
            const name = bridge.getName();

            try writer.print("bridge {s} create\n", .{name});

            // Add ports
            for (bridge.ports.items) |port_index| {
                if (state.findInterfaceByIndex(port_index)) |port| {
                    try writer.print("bridge {s} add {s}\n", .{ name, port.getName() });
                }
            }
        }

        try writer.print("\n", .{});
    }

    fn exportVlans(self: *Self, state: *const types.NetworkState, writer: anytype) !void {
        if (self.options.comments) {
            try writer.print("# VLANs\n", .{});
        }

        for (state.vlans.items) |vlan| {
            // Find parent interface name
            if (state.findInterfaceByIndex(vlan.parent_index)) |parent| {
                try writer.print("vlan {d} on {s}\n", .{ vlan.vlan_id, parent.getName() });
            }
        }

        try writer.print("\n", .{});
    }

    fn exportInterfaces(self: *Self, state: *const types.NetworkState, writer: anytype) !void {
        if (self.options.comments) {
            try writer.print("# Interfaces\n", .{});
        }

        for (state.interfaces.items) |iface| {
            const name = iface.getName();

            // Skip loopback if configured
            if (self.options.skip_loopback and iface.link_type == .loopback) {
                continue;
            }

            // Skip if only_up and interface is down
            if (self.options.only_up and !iface.isUp()) {
                continue;
            }

            // Skip VLAN sub-interfaces (handled in VLANs section)
            if (iface.link_type == .vlan) {
                continue;
            }

            // Interface state
            const state_str = if (iface.isUp()) "up" else "down";
            try writer.print("interface {s} set state {s}\n", .{ name, state_str });

            // MTU (skip default 1500 for physical interfaces)
            if (iface.mtu != 1500 or iface.link_type != .physical) {
                try writer.print("interface {s} set mtu {d}\n", .{ name, iface.mtu });
            }
        }

        try writer.print("\n", .{});
    }

    fn exportAddresses(self: *Self, state: *const types.NetworkState, writer: anytype) !void {
        if (self.options.comments) {
            try writer.print("# Addresses\n", .{});
        }

        for (state.addresses.items) |addr| {
            // Skip if we're skipping auto addresses
            if (self.options.skip_auto_addresses) {
                // Skip link-local (169.254.x.x for IPv4, fe80:: for IPv6)
                if (addr.isIPv4()) {
                    if (addr.address[0] == 169 and addr.address[1] == 254) {
                        continue;
                    }
                } else if (addr.isIPv6()) {
                    if (addr.address[0] == 0xfe and (addr.address[1] & 0xc0) == 0x80) {
                        continue;
                    }
                }

                // Skip IPv6 addresses that are not global scope
                if (addr.isIPv6() and addr.scope != 0) { // 0 = RT_SCOPE_UNIVERSE
                    continue;
                }
            }

            // Find interface name
            const iface_name = blk: {
                if (addr.interface_name_len > 0) {
                    break :blk addr.getInterfaceName();
                }
                if (state.findInterfaceByIndex(addr.interface_index)) |iface| {
                    break :blk iface.getName();
                }
                continue; // Skip if we can't find interface
            };

            // Skip loopback addresses if configured
            if (self.options.skip_loopback) {
                if (state.findInterface(iface_name)) |iface| {
                    if (iface.link_type == .loopback) {
                        continue;
                    }
                }
            }

            // Format address
            var addr_buf: [64]u8 = undefined;
            const addr_str = try formatAddress(&addr, &addr_buf);

            try writer.print("interface {s} address {s}/{d}\n", .{ iface_name, addr_str, addr.prefix_len });
        }

        try writer.print("\n", .{});
    }

    fn exportRoutes(self: *Self, state: *const types.NetworkState, writer: anytype) !void {
        if (self.options.comments) {
            try writer.print("# Routes\n", .{});
        }

        for (state.routes.items) |route| {
            // Skip kernel routes if configured
            if (self.options.skip_kernel_routes) {
                // RTPROT_KERNEL = 2, RTPROT_REDIRECT = 1
                // Only keep RTPROT_BOOT (3), RTPROT_STATIC (4), and higher
                if (route.protocol <= 2) {
                    continue;
                }
            }

            // Skip non-main table routes
            if (route.table != 254) { // RT_TABLE_MAIN
                continue;
            }

            // Skip non-unicast routes
            if (route.route_type != 1) { // RTN_UNICAST
                continue;
            }

            var dst_buf: [64]u8 = undefined;
            var gw_buf: [64]u8 = undefined;

            if (route.isDefault()) {
                // Default route
                if (route.has_gateway) {
                    const gw_str = try formatAddressBytes(route.family, &route.gateway, &gw_buf);
                    try writer.print("route default via {s}\n", .{gw_str});
                }
            } else {
                // Network route
                const dst_str = try formatAddressBytes(route.family, &route.dst, &dst_buf);

                if (route.has_gateway) {
                    const gw_str = try formatAddressBytes(route.family, &route.gateway, &gw_buf);
                    try writer.print("route {s}/{d} via {s}\n", .{ dst_str, route.dst_len, gw_str });
                } else if (route.oif != 0) {
                    // Route via interface
                    if (state.findInterfaceByIndex(@intCast(route.oif))) |iface| {
                        try writer.print("route {s}/{d} dev {s}\n", .{ dst_str, route.dst_len, iface.getName() });
                    }
                }
            }
        }

        try writer.print("\n", .{});
    }

    fn formatAddress(addr: *const types.AddressState, buf: []u8) ![]const u8 {
        return formatAddressBytes(addr.family, &addr.address, buf);
    }

    fn formatAddressBytes(family: u8, bytes: *const [16]u8, buf: []u8) ![]const u8 {
        if (family == 2) { // AF_INET
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                bytes[0], bytes[1], bytes[2], bytes[3],
            }) catch return error.FormatError;
        } else if (family == 10) { // AF_INET6
            // Simplified IPv6 formatting
            return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                bytes[0],  bytes[1],  bytes[2],  bytes[3],
                bytes[4],  bytes[5],  bytes[6],  bytes[7],
                bytes[8],  bytes[9],  bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15],
            }) catch return error.FormatError;
        }
        return error.UnsupportedFamily;
    }

    fn bondModeToString(mode: types.BondState.BondMode) []const u8 {
        return switch (mode) {
            .balance_rr => "0",
            .active_backup => "1",
            .balance_xor => "2",
            .broadcast => "3",
            .@"802.3ad" => "4",
            .balance_tlb => "5",
            .balance_alb => "6",
        };
    }
};

// Tests

test "export options presets" {
    const all = ExportOptions.all;
    try std.testing.expect(all.interfaces);
    try std.testing.expect(all.routes);

    const routes = ExportOptions.routes_only;
    try std.testing.expect(!routes.interfaces);
    try std.testing.expect(routes.routes);
}

test "exporter init" {
    const allocator = std.testing.allocator;
    const exporter = StateExporter.init(allocator, ExportOptions.all);
    _ = exporter;
}

test "export empty state" {
    const allocator = std.testing.allocator;
    var state = types.NetworkState.init(allocator);
    defer state.deinit();

    var exporter = StateExporter.init(allocator, ExportOptions{ .comments = false });
    const output = try exporter.exportToString(&state);
    defer allocator.free(output);

    try std.testing.expect(output.len > 0);
}
