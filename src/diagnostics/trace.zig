const std = @import("std");
const live = @import("../state/live.zig");
const types = @import("../state/types.zig");
const topology = @import("../analysis/topology.zig");
const neighbor = @import("../netlink/neighbor.zig");
const native_ping = @import("../plugins/native/ping.zig");

/// Status of a path component
pub const ComponentStatus = enum {
    ok,
    warning,
    error_state,
    unknown,

    pub fn symbol(self: ComponentStatus) []const u8 {
        return switch (self) {
            .ok => "[OK]",
            .warning => "[WARN]",
            .error_state => "[ERR]",
            .unknown => "[?]",
        };
    }
};

/// A single hop in the network path
pub const PathHop = struct {
    name: []const u8,
    hop_type: HopType,
    status: ComponentStatus,
    details: []const u8,
    index: i32,
    // Additional info
    mac: ?[6]u8,
    state_up: bool,
    master_name: ?[]const u8,
    vlan_id: ?u16,
    veth_peer_name: ?[]const u8,
    veth_peer_netns: ?i32, // null = same namespace, value = other namespace

    pub const HopType = enum {
        source,
        bridge,
        bond,
        vlan,
        veth,
        veth_peer,
        physical,
        gateway,
        destination,
    };

    pub fn format(self: *const PathHop, writer: anytype, indent: usize) !void {
        // Indent
        for (0..indent) |_| {
            try writer.print("  ", .{});
        }

        // Status symbol
        try writer.print("{s} ", .{self.status.symbol()});

        // Name and type
        const type_str = switch (self.hop_type) {
            .source => "source",
            .bridge => "bridge",
            .bond => "bond",
            .vlan => "vlan",
            .veth => "veth",
            .veth_peer => "veth peer",
            .physical => "physical",
            .gateway => "gateway",
            .destination => "destination",
        };
        try writer.print("{s} ({s})", .{ self.name, type_str });

        // State
        if (self.hop_type != .gateway and self.hop_type != .destination) {
            if (self.state_up) {
                try writer.print(" UP", .{});
            } else {
                try writer.print(" DOWN", .{});
            }
        }

        // VLAN ID
        if (self.vlan_id) |vid| {
            try writer.print(" vlan:{d}", .{vid});
        }

        // Veth peer info
        if (self.veth_peer_name) |peer| {
            if (self.veth_peer_netns) |ns| {
                try writer.print(" -> {s}@netns{d}", .{ peer, ns });
            } else {
                try writer.print(" -> {s}", .{peer});
            }
        }

        // Master
        if (self.master_name) |master| {
            try writer.print(" master:{s}", .{master});
        }

        try writer.print("\n", .{});

        // Details on separate line if present
        if (self.details.len > 0) {
            for (0..indent + 1) |_| {
                try writer.print("  ", .{});
            }
            try writer.print("  {s}\n", .{self.details});
        }
    }
};

/// Network path trace result
pub const PathTrace = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    destination: []const u8,
    hops: std.array_list.Managed(PathHop),
    issues: std.array_list.Managed([]const u8),
    allocated_strings: std.array_list.Managed([]const u8),
    reachable: bool,
    rtt_us: ?u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) Self {
        return Self{
            .allocator = allocator,
            .source = source,
            .destination = destination,
            .hops = std.array_list.Managed(PathHop).init(allocator),
            .issues = std.array_list.Managed([]const u8).init(allocator),
            .allocated_strings = std.array_list.Managed([]const u8).init(allocator),
            .reachable = false,
            .rtt_us = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.hops.deinit();
        for (self.issues.items) |issue| {
            self.allocator.free(issue);
        }
        self.issues.deinit();
        for (self.allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self.allocated_strings.deinit();
    }

    pub fn addIssue(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.issues.append(msg);
    }

    pub fn overallStatus(self: *const Self) ComponentStatus {
        var worst: ComponentStatus = .ok;
        for (self.hops.items) |hop| {
            if (@intFromEnum(hop.status) > @intFromEnum(worst)) {
                worst = hop.status;
            }
        }
        return worst;
    }

    pub fn format(self: *const Self, writer: anytype) !void {
        try writer.print("\n", .{});
        try writer.print("Path Trace: {s} -> {s}\n", .{ self.source, self.destination });
        try writer.print("==================================================\n\n", .{});

        // Show path
        try writer.print("Network Path:\n", .{});
        for (self.hops.items, 0..) |*hop, i| {
            try hop.format(writer, 1);
            // Draw connector
            if (i < self.hops.items.len - 1) {
                try writer.print("      |\n", .{});
                try writer.print("      v\n", .{});
            }
        }

        try writer.print("\n", .{});

        // Reachability
        try writer.print("Reachability:\n", .{});
        if (self.reachable) {
            try writer.print("  [OK] Destination is reachable", .{});
            if (self.rtt_us) |rtt| {
                const rtt_ms = @as(f64, @floatFromInt(rtt)) / 1000.0;
                try writer.print(" (RTT: {d:.2}ms)", .{rtt_ms});
            }
            try writer.print("\n", .{});
        } else {
            try writer.print("  [ERR] Destination is NOT reachable\n", .{});
        }

        // Issues summary
        if (self.issues.items.len > 0) {
            try writer.print("\nIssues Found ({d}):\n", .{self.issues.items.len});
            for (self.issues.items) |issue| {
                try writer.print("  - {s}\n", .{issue});
            }
        }

        // Overall status
        try writer.print("\nOverall: {s}\n", .{self.overallStatus().symbol()});
    }
};

/// Path tracer - builds and validates network paths
pub const PathTracer = struct {
    allocator: std.mem.Allocator,
    state: types.NetworkState,
    topo: ?topology.TopologyGraph,
    neighbors: ?[]neighbor.NeighborEntry,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Get live network state
        var state = try live.queryLiveState(allocator);
        errdefer state.deinit();

        // Build topology
        var topo = try topology.TopologyGraph.buildFromState(allocator, &state);
        errdefer topo.deinit();

        // Get neighbor table
        const neighbors = neighbor.getNeighbors(allocator) catch null;

        return Self{
            .allocator = allocator,
            .state = state,
            .topo = topo,
            .neighbors = neighbors,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.topo) |*t| {
            t.deinit();
        }
        if (self.neighbors) |n| {
            self.allocator.free(n);
        }
        self.state.deinit();
    }

    /// Trace path from interface to destination IP
    pub fn tracePath(self: *Self, source_iface: []const u8, dest_ip: []const u8) !PathTrace {
        var trace = PathTrace.init(self.allocator, source_iface, dest_ip);

        // Find source interface in state
        const source = self.findInterface(source_iface);
        if (source == null) {
            try trace.addIssue("Source interface '{s}' not found", .{source_iface});
            return trace;
        }

        // Add source hop
        const src = source.?;
        const src_up = src.isUp();

        // Check if source is a veth
        var veth_peer_name: ?[]const u8 = null;
        var veth_peer_netns: ?i32 = null;
        const is_veth = src.link_type == .veth;
        if (is_veth) {
            if (self.state.findVeth(src.index)) |veth| {
                veth_peer_netns = veth.peer_netns_id;
                if (veth.peer_netns_id == null) {
                    // Peer is in same namespace, get its name
                    if (self.findInterfaceByIndex(veth.peer_index)) |peer| {
                        veth_peer_name = peer.getName();
                    }
                }
            }
        }

        try trace.hops.append(PathHop{
            .name = source_iface,
            .hop_type = if (is_veth) .veth else .source,
            .status = if (src_up) .ok else .error_state,
            .details = if (!src_up) "Interface is DOWN" else "",
            .index = src.index,
            .mac = src.mac,
            .state_up = src_up,
            .master_name = null,
            .vlan_id = null,
            .veth_peer_name = veth_peer_name,
            .veth_peer_netns = veth_peer_netns,
        });

        // If veth with peer in same namespace, add the peer to the path
        if (is_veth and veth_peer_name != null) {
            if (self.state.findVeth(src.index)) |veth| {
                if (self.findInterfaceByIndex(veth.peer_index)) |peer| {
                    const peer_up = peer.isUp();
                    try trace.hops.append(PathHop{
                        .name = peer.getName(),
                        .hop_type = .veth_peer,
                        .status = if (peer_up) .ok else .error_state,
                        .details = if (!peer_up) "Peer interface is DOWN" else "",
                        .index = peer.index,
                        .mac = peer.mac,
                        .state_up = peer_up,
                        .master_name = null,
                        .vlan_id = null,
                        .veth_peer_name = source_iface,
                        .veth_peer_netns = null,
                    });

                    if (!peer_up) {
                        try trace.addIssue("Veth peer {s} is DOWN", .{peer.getName()});
                    }
                }
            }
        } else if (is_veth and veth_peer_netns != null) {
            try trace.addIssue("Veth peer is in different namespace (netns {?d})", .{veth_peer_netns});
        }

        if (!src_up) {
            try trace.addIssue("Source interface {s} is DOWN", .{source_iface});
        }

        // Walk up through masters (bond -> bridge chain)
        try self.walkMasterChain(&trace, source.?);

        // Find egress interface (the physical interface that will send packets)
        const egress = self.findEgressInterface(src);
        if (egress) |eg| {
            const eg_name = eg.getName();
            if (!std.mem.eql(u8, eg_name, source_iface)) {
                const eg_up = eg.isUp();
                try trace.hops.append(PathHop{
                    .name = eg_name,
                    .hop_type = .physical,
                    .status = if (eg_up) .ok else .error_state,
                    .details = "",
                    .index = eg.index,
                    .mac = eg.mac,
                    .state_up = eg_up,
                    .master_name = null,
                    .vlan_id = null,
                    .veth_peer_name = null,
                    .veth_peer_netns = null,
                });
            }
        }

        // Check for gateway
        const gateway = self.findGatewayFor(dest_ip);
        if (gateway) |gw| {
            // Allocate string for gateway IP (tracked for cleanup)
            const gw_str = try std.fmt.allocPrint(self.allocator, "{d}.{d}.{d}.{d}", .{
                gw[0], gw[1], gw[2], gw[3],
            });
            try trace.allocated_strings.append(gw_str);

            // Check if gateway has ARP entry
            const gw_arp = self.findNeighborByIP(gw);
            const gw_status: ComponentStatus = if (gw_arp != null) .ok else .warning;
            const gw_details: []const u8 = if (gw_arp == null) "No ARP entry for gateway" else "";

            try trace.hops.append(PathHop{
                .name = gw_str,
                .hop_type = .gateway,
                .status = gw_status,
                .details = gw_details,
                .index = 0,
                .mac = if (gw_arp) |a| a.lladdr else null,
                .state_up = true,
                .master_name = null,
                .vlan_id = null,
                .veth_peer_name = null,
                .veth_peer_netns = null,
            });

            if (gw_arp == null) {
                try trace.addIssue("No ARP entry for gateway {s}", .{gw_str});
            }
        }

        // Add destination
        const dest_arp = self.findNeighborByIPStr(dest_ip);
        try trace.hops.append(PathHop{
            .name = dest_ip,
            .hop_type = .destination,
            .status = if (dest_arp != null) .ok else .unknown,
            .details = if (dest_arp != null) "ARP entry exists" else "No ARP entry (may be normal for remote hosts)",
            .index = 0,
            .mac = if (dest_arp) |a| a.lladdr else null,
            .state_up = true,
            .master_name = null,
            .vlan_id = null,
            .veth_peer_name = null,
            .veth_peer_netns = null,
        });

        // Test reachability with ping
        const ping_result = native_ping.ping(self.allocator, dest_ip, .{
            .count = 1,
            .timeout_ms = 2000,
        }) catch null;

        if (ping_result) |pr| {
            trace.reachable = pr.isReachable();
            trace.rtt_us = pr.rtt_min_us;

            if (!pr.isReachable()) {
                try trace.addIssue("Ping to {s} failed - destination unreachable", .{dest_ip});
            }
        }

        return trace;
    }

    /// Walk up the master chain (interface -> bond/bridge -> physical)
    fn walkMasterChain(self: *Self, trace: *PathTrace, iface: types.InterfaceState) !void {
        var current = iface;

        while (current.master_index) |master_idx| {
            const master = self.findInterfaceByIndex(master_idx);
            if (master == null) break;

            const m = master.?;
            const m_name = m.getName();
            const m_up = m.isUp();
            const hop_type: PathHop.HopType = blk: {
                // Determine type based on interface characteristics
                if (self.isBridge(m_name)) break :blk .bridge;
                if (self.isBond(m_name)) break :blk .bond;
                break :blk .physical;
            };

            var details_buf: [128]u8 = undefined;
            var details: []const u8 = "";

            // Get additional details based on type
            if (hop_type == .bridge) {
                const port_count = self.countBridgePorts(m_name);
                details = std.fmt.bufPrint(&details_buf, "{d} ports attached", .{port_count}) catch "";
            } else if (hop_type == .bond) {
                const slave_count = self.countBondSlaves(m_name);
                details = std.fmt.bufPrint(&details_buf, "{d} slaves", .{slave_count}) catch "";
            }

            try trace.hops.append(PathHop{
                .name = m_name,
                .hop_type = hop_type,
                .status = if (m_up) .ok else .error_state,
                .details = details,
                .index = m.index,
                .mac = m.mac,
                .state_up = m_up,
                .master_name = null,
                .vlan_id = null,
                .veth_peer_name = null,
                .veth_peer_netns = null,
            });

            if (!m_up) {
                try trace.addIssue("{s} {s} is DOWN", .{ @tagName(hop_type), m_name });
            }

            current = m;
        }
    }

    fn findInterface(self: *Self, name: []const u8) ?types.InterfaceState {
        for (self.state.interfaces.items) |iface| {
            if (std.mem.eql(u8, iface.getName(), name)) {
                return iface;
            }
        }
        return null;
    }

    fn findInterfaceByIndex(self: *Self, index: i32) ?types.InterfaceState {
        for (self.state.interfaces.items) |iface| {
            if (iface.index == index) {
                return iface;
            }
        }
        return null;
    }

    fn findEgressInterface(self: *Self, start: types.InterfaceState) ?types.InterfaceState {
        var current = start;

        // Walk up masters to find physical egress
        while (current.master_index) |master_idx| {
            const master = self.findInterfaceByIndex(master_idx);
            if (master == null) break;
            current = master.?;
        }

        // If current is a bond, find an active slave
        if (self.isBond(current.getName())) {
            for (self.state.interfaces.items) |iface| {
                if (iface.master_index) |mi| {
                    if (mi == current.index and iface.isUp()) {
                        return iface;
                    }
                }
            }
        }

        return current;
    }

    fn isBridge(self: *Self, name: []const u8) bool {
        for (self.state.bridges.items) |*br| {
            if (std.mem.eql(u8, br.getName(), name)) {
                return true;
            }
        }
        return false;
    }

    fn isBond(self: *Self, name: []const u8) bool {
        for (self.state.bonds.items) |*bond| {
            if (std.mem.eql(u8, bond.getName(), name)) {
                return true;
            }
        }
        return false;
    }

    fn countBridgePorts(self: *Self, bridge_name: []const u8) usize {
        const br = self.findInterface(bridge_name);
        if (br == null) return 0;

        var count: usize = 0;
        for (self.state.interfaces.items) |iface| {
            if (iface.master_index) |mi| {
                if (mi == br.?.index) count += 1;
            }
        }
        return count;
    }

    fn countBondSlaves(self: *Self, bond_name: []const u8) usize {
        const bond = self.findInterface(bond_name);
        if (bond == null) return 0;

        var count: usize = 0;
        for (self.state.interfaces.items) |iface| {
            if (iface.master_index) |mi| {
                if (mi == bond.?.index) count += 1;
            }
        }
        return count;
    }

    fn findGatewayFor(self: *Self, dest_ip: []const u8) ?[4]u8 {
        _ = dest_ip;
        // Look for default route
        for (self.state.routes.items) |route| {
            // Check if it's a default route (dst_len == 0 means 0.0.0.0/0)
            if (route.isDefault() and route.has_gateway) {
                // Gateway is stored as raw IPv4 bytes for AF_INET
                if (route.family == 2) { // AF_INET
                    return route.gateway[0..4].*;
                }
            }
        }
        return null;
    }

    fn findNeighborByIP(self: *Self, ip: [4]u8) ?neighbor.NeighborEntry {
        if (self.neighbors == null) return null;

        for (self.neighbors.?) |n| {
            if (n.family == 2 and std.mem.eql(u8, n.address[0..4], &ip)) {
                return n;
            }
        }
        return null;
    }

    fn findNeighborByIPStr(self: *Self, ip_str: []const u8) ?neighbor.NeighborEntry {
        const ip = parseIPv4(ip_str) orelse return null;
        return self.findNeighborByIP(ip);
    }
};

fn parseIPv4(s: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var part: usize = 0;
    var value: u16 = 0;
    var has_digit = false;

    for (s) |c| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + (c - '0');
            if (value > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or part >= 3) return null;
            result[part] = @truncate(value);
            part += 1;
            value = 0;
            has_digit = false;
        } else {
            return null;
        }
    }

    if (!has_digit or part != 3) return null;
    result[3] = @truncate(value);
    return result;
}

/// Convenience function
pub fn tracePath(allocator: std.mem.Allocator, source: []const u8, dest: []const u8) !PathTrace {
    var tracer = try PathTracer.init(allocator);
    defer tracer.deinit();
    return tracer.tracePath(source, dest);
}

// Tests

test "parseIPv4" {
    const ip = parseIPv4("192.168.1.1");
    try std.testing.expect(ip != null);
    try std.testing.expectEqual(@as(u8, 192), ip.?[0]);
}
