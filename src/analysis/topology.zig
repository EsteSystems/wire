const std = @import("std");
const state_types = @import("../state/types.zig");

/// Node type in the topology graph
pub const NodeType = enum {
    physical,
    bond,
    bridge,
    vlan,
    veth,
    tap,
    tun,
    loopback,
    unknown,

    pub fn fromLinkType(link_type: state_types.InterfaceState.LinkType) NodeType {
        return switch (link_type) {
            .physical => .physical,
            .bond => .bond,
            .bridge => .bridge,
            .vlan => .vlan,
            .veth => .veth,
            .tap => .tap,
            .tun => .tun,
            .loopback => .loopback,
            .other => .unknown,
        };
    }

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .physical => "physical",
            .bond => "bond",
            .bridge => "bridge",
            .vlan => "VLAN",
            .veth => "veth",
            .tap => "tap",
            .tun => "tun",
            .loopback => "loopback",
            .unknown => "unknown",
        };
    }
};

/// A node in the topology graph
pub const TopoNode = struct {
    index: i32,
    name: [16]u8,
    name_len: usize,
    node_type: NodeType,
    is_up: bool,
    has_carrier: bool,
    // Parent relationship (e.g., bond0 is parent of eth0 if eth0 is enslaved)
    parent_index: ?i32,
    // VLAN-specific
    vlan_id: ?u16,

    const Self = @This();

    pub fn getName(self: *const Self) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn format(self: *const Self, writer: anytype) !void {
        try writer.print("{s} ({s})", .{ self.getName(), self.node_type.toString() });
        if (self.vlan_id) |vid| {
            try writer.print(" id={d}", .{vid});
        }
        if (!self.is_up) {
            try writer.print(" [DOWN]", .{});
        } else if (!self.has_carrier) {
            try writer.print(" [NO-CARRIER]", .{});
        }
    }
};

/// Edge types for relationships
pub const EdgeType = enum {
    enslaved, // Interface is enslaved to a bond/bridge
    vlan_parent, // VLAN interface on top of parent
    veth_peer, // veth peer relationship
};

/// An edge in the topology graph
pub const TopoEdge = struct {
    from_index: i32,
    to_index: i32,
    edge_type: EdgeType,
};

/// Topology graph - represents interface relationships
pub const TopologyGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(TopoNode),
    edges: std.ArrayList(TopoEdge),
    // Index lookup for fast access
    index_map: std.AutoHashMap(i32, usize),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .nodes = std.ArrayList(TopoNode).init(allocator),
            .edges = std.ArrayList(TopoEdge).init(allocator),
            .index_map = std.AutoHashMap(i32, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit();
        self.edges.deinit();
        self.index_map.deinit();
    }

    /// Build topology from network state
    pub fn buildFromState(allocator: std.mem.Allocator, state: *const state_types.NetworkState) !Self {
        var graph = Self.init(allocator);
        errdefer graph.deinit();

        // First pass: add all interfaces as nodes
        for (state.interfaces.items) |*iface| {
            var node = TopoNode{
                .index = iface.index,
                .name = iface.name,
                .name_len = iface.name_len,
                .node_type = NodeType.fromLinkType(iface.link_type),
                .is_up = iface.isUp(),
                .has_carrier = iface.hasCarrier(),
                .parent_index = iface.master_index,
                .vlan_id = null,
            };

            // Check if this is a VLAN
            for (state.vlans.items) |vlan| {
                if (vlan.index == iface.index) {
                    node.vlan_id = vlan.vlan_id;
                    node.parent_index = vlan.parent_index;
                    break;
                }
            }

            const node_idx = graph.nodes.items.len;
            try graph.nodes.append(node);
            try graph.index_map.put(iface.index, node_idx);
        }

        // Second pass: build edges from relationships
        for (graph.nodes.items) |node| {
            if (node.parent_index) |parent_idx| {
                const edge_type: EdgeType = if (node.vlan_id != null) .vlan_parent else .enslaved;
                try graph.edges.append(TopoEdge{
                    .from_index = node.index,
                    .to_index = parent_idx,
                    .edge_type = edge_type,
                });
            }
        }

        return graph;
    }

    /// Find node by interface index
    pub fn findNode(self: *const Self, index: i32) ?*const TopoNode {
        if (self.index_map.get(index)) |node_idx| {
            return &self.nodes.items[node_idx];
        }
        return null;
    }

    /// Find node by name
    pub fn findNodeByName(self: *const Self, name: []const u8) ?*const TopoNode {
        for (self.nodes.items) |*node| {
            if (std.mem.eql(u8, node.getName(), name)) {
                return node;
            }
        }
        return null;
    }

    /// Get children of a node (interfaces enslaved to it or VLANs on top of it)
    pub fn getChildren(self: *const Self, parent_index: i32, allocator: std.mem.Allocator) ![]const TopoNode {
        var children = std.ArrayList(TopoNode).init(allocator);
        errdefer children.deinit();

        for (self.edges.items) |edge| {
            if (edge.to_index == parent_index) {
                if (self.findNode(edge.from_index)) |node| {
                    try children.append(node.*);
                }
            }
        }

        return children.toOwnedSlice();
    }

    /// Get parent chain (walk up the hierarchy)
    pub fn getParentChain(self: *const Self, start_index: i32, allocator: std.mem.Allocator) ![]const TopoNode {
        var chain = std.ArrayList(TopoNode).init(allocator);
        errdefer chain.deinit();

        var current_index: ?i32 = start_index;

        while (current_index) |idx| {
            if (self.findNode(idx)) |node| {
                try chain.append(node.*);
                current_index = node.parent_index;
            } else {
                break;
            }
        }

        return chain.toOwnedSlice();
    }

    /// Get root nodes (nodes with no parent)
    pub fn getRootNodes(self: *const Self, allocator: std.mem.Allocator) ![]const TopoNode {
        var roots = std.ArrayList(TopoNode).init(allocator);
        errdefer roots.deinit();

        for (self.nodes.items) |node| {
            if (node.parent_index == null and node.node_type != .loopback) {
                try roots.append(node);
            }
        }

        return roots.toOwnedSlice();
    }

    /// Find path between two interfaces. Returns null if either endpoint not found.
    pub fn findPath(self: *const Self, src_name: []const u8, dst_name: []const u8, allocator: std.mem.Allocator) !?[]const TopoNode {
        const src_node = self.findNodeByName(src_name) orelse return null;
        const dst_node = self.findNodeByName(dst_name) orelse return null;

        // Get parent chains for both
        const src_chain = try self.getParentChain(src_node.index, allocator);
        defer allocator.free(src_chain);
        const dst_chain = try self.getParentChain(dst_node.index, allocator);
        defer allocator.free(dst_chain);

        // Find common ancestor
        var common_idx: ?i32 = null;
        outer: for (src_chain) |s| {
            for (dst_chain) |d| {
                if (s.index == d.index) {
                    common_idx = s.index;
                    break :outer;
                }
            }
        }

        // Build path
        var path = std.ArrayList(TopoNode).init(allocator);
        errdefer path.deinit();

        // Add source chain up to common
        for (src_chain) |node| {
            try path.append(node);
            if (common_idx != null and node.index == common_idx.?) break;
        }

        // Add destination chain in reverse (skip common if found)
        if (dst_chain.len > 0) {
            var i: usize = dst_chain.len;
            while (i > 0) {
                i -= 1;
                const node = dst_chain[i];
                if (common_idx != null and node.index == common_idx.?) continue;
                try path.append(node);
            }
        }

        const result = try path.toOwnedSlice();
        return result;
    }

    /// Display topology as tree
    pub fn displayTree(self: *const Self, writer: anytype) !void {
        const roots = try self.getRootNodes(self.allocator);
        defer self.allocator.free(roots);

        if (roots.len == 0 and self.nodes.items.len == 0) {
            try writer.print("No network topology found.\n", .{});
            return;
        }

        try writer.print("Network Topology\n", .{});
        try writer.print("================\n\n", .{});

        // Display each root and its children
        for (roots) |root| {
            try self.displayNodeTree(writer, root.index, 0);
            try writer.print("\n", .{});
        }

        // Show loopback separately
        for (self.nodes.items) |node| {
            if (node.node_type == .loopback) {
                try writer.print("lo (loopback)\n", .{});
            }
        }
    }

    /// Recursively display a node and its children
    fn displayNodeTree(self: *const Self, writer: anytype, node_index: i32, depth: usize) !void {
        const node = self.findNode(node_index) orelse return;

        // Indentation
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            if (i == depth - 1) {
                try writer.print("  +-- ", .{});
            } else {
                try writer.print("  |   ", .{});
            }
        }

        if (depth == 0) {
            try node.format(writer);
        } else {
            try node.format(writer);
        }
        try writer.print("\n", .{});

        // Get and display children
        const children = try self.getChildren(node_index, self.allocator);
        defer self.allocator.free(children);

        for (children) |child| {
            try self.displayNodeTree(writer, child.index, depth + 1);
        }
    }

    /// Display path between two interfaces
    pub fn displayPath(_: *const Self, path: []const TopoNode, writer: anytype) !void {
        if (path.len == 0) {
            try writer.print("No path found.\n", .{});
            return;
        }

        try writer.print("Path ({d} hops):\n", .{path.len});

        for (path, 0..) |*node, i| {
            if (i > 0) {
                try writer.print("  |\n", .{});
                try writer.print("  v\n", .{});
            }
            try writer.print("  ", .{});
            try node.format(writer);
            try writer.print("\n", .{});
        }
    }

    /// Validate path - check all interfaces are UP with carrier
    pub fn validatePath(self: *const Self, path: []const TopoNode) PathValidation {
        var result = PathValidation{
            .all_up = true,
            .all_have_carrier = true,
            .issues = std.ArrayList(PathIssue).init(self.allocator),
        };

        for (path) |node| {
            if (!node.is_up) {
                result.all_up = false;
                result.issues.append(PathIssue{
                    .interface_name = node.name,
                    .interface_name_len = node.name_len,
                    .issue = .interface_down,
                }) catch {};
            }
            if (node.is_up and !node.has_carrier and node.node_type == .physical) {
                result.all_have_carrier = false;
                result.issues.append(PathIssue{
                    .interface_name = node.name,
                    .interface_name_len = node.name_len,
                    .issue = .no_carrier,
                }) catch {};
            }
        }

        return result;
    }
};

/// Issue types for path validation
pub const IssueType = enum {
    interface_down,
    no_carrier,
};

/// Path issue
pub const PathIssue = struct {
    interface_name: [16]u8,
    interface_name_len: usize,
    issue: IssueType,

    pub fn getName(self: *const PathIssue) []const u8 {
        return self.interface_name[0..self.interface_name_len];
    }
};

/// Path validation result
pub const PathValidation = struct {
    all_up: bool,
    all_have_carrier: bool,
    issues: std.ArrayList(PathIssue),

    pub fn deinit(self: *PathValidation) void {
        self.issues.deinit();
    }

    pub fn isValid(self: *const PathValidation) bool {
        return self.all_up and self.all_have_carrier;
    }

    pub fn format(self: *const PathValidation, writer: anytype) !void {
        if (self.isValid()) {
            try writer.print("Path validation: OK\n", .{});
            try writer.print("  All interfaces UP with carrier\n", .{});
        } else {
            try writer.print("Path validation: ISSUES FOUND\n", .{});
            for (self.issues.items) |issue| {
                const issue_str = switch (issue.issue) {
                    .interface_down => "interface is DOWN",
                    .no_carrier => "no carrier detected",
                };
                try writer.print("  {s}: {s}\n", .{ issue.getName(), issue_str });
            }
        }
    }
};

// Tests

test "TopologyGraph init and deinit" {
    const allocator = std.testing.allocator;
    var graph = TopologyGraph.init(allocator);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 0), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
}

test "NodeType fromLinkType" {
    try std.testing.expectEqual(NodeType.physical, NodeType.fromLinkType(.physical));
    try std.testing.expectEqual(NodeType.bond, NodeType.fromLinkType(.bond));
    try std.testing.expectEqual(NodeType.bridge, NodeType.fromLinkType(.bridge));
    try std.testing.expectEqual(NodeType.vlan, NodeType.fromLinkType(.vlan));
}

test "TopoNode getName" {
    var node = TopoNode{
        .index = 1,
        .name = undefined,
        .name_len = 4,
        .node_type = .physical,
        .is_up = true,
        .has_carrier = true,
        .parent_index = null,
        .vlan_id = null,
    };
    @memcpy(node.name[0..4], "eth0");

    try std.testing.expectEqualStrings("eth0", node.getName());
}
