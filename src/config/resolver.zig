const std = @import("std");
const parser = @import("../syntax/parser.zig");

/// Dependency resolution for network configuration
/// Ensures commands are executed in correct order:
/// 1. Bonds/bridges before their members
/// 2. Parent interfaces before VLANs
/// 3. Interfaces before addresses/routes

pub const DependencyError = error{
    CircularDependency,
    OutOfMemory,
    UnresolvableDependency,
};

/// Node in the dependency graph
const Node = struct {
    command: *const parser.Command,
    name: []const u8,
    node_type: NodeType,
    dependencies: std.ArrayList(usize),
    dependents: std.ArrayList(usize),
    visited: bool = false,
    in_stack: bool = false,

    fn init(allocator: std.mem.Allocator, cmd: *const parser.Command) Node {
        return Node{
            .command = cmd,
            .name = getCommandName(cmd),
            .node_type = getNodeType(cmd),
            .dependencies = std.ArrayList(usize).init(allocator),
            .dependents = std.ArrayList(usize).init(allocator),
        };
    }

    fn deinit(self: *Node) void {
        self.dependencies.deinit();
        self.dependents.deinit();
    }
};

const NodeType = enum {
    bond_create,
    bridge_create,
    vlan_create,
    interface_config,
    bond_member,
    bridge_member,
    address_add,
    route_add,
    other,
};

fn getNodeType(cmd: *const parser.Command) NodeType {
    switch (cmd.subject) {
        .bond => |b| {
            if (b.name != null) {
                switch (cmd.action) {
                    .create => return .bond_create,
                    .add => return .bond_member,
                    else => {},
                }
            }
        },
        .bridge => |b| {
            if (b.name != null) {
                switch (cmd.action) {
                    .create => return .bridge_create,
                    .add => return .bridge_member,
                    else => {},
                }
            }
        },
        .vlan => return .vlan_create,
        .interface => |i| {
            if (i.name != null) {
                switch (cmd.action) {
                    .add => return .address_add,
                    .set => return .interface_config,
                    else => {},
                }
            }
        },
        .route => {
            switch (cmd.action) {
                .add => return .route_add,
                else => {},
            }
        },
        else => {},
    }
    return .other;
}

fn getCommandName(cmd: *const parser.Command) []const u8 {
    switch (cmd.subject) {
        .bond => |b| return b.name orelse "",
        .bridge => |b| return b.name orelse "",
        .vlan => |v| return v.parent orelse "",
        .veth => |v| return v.name orelse "",
        .interface => |i| return i.name orelse "",
        .route => return "route",
        .analyze => return "analyze",
    }
}

/// Dependency resolver
pub const Resolver = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    name_to_index: std.StringHashMap(usize),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .nodes = std.ArrayList(Node).init(allocator),
            .name_to_index = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit();
        self.name_to_index.deinit();
    }

    /// Add commands to the resolver
    pub fn addCommands(self: *Self, commands: []const parser.Command) !void {
        // First pass: create all nodes
        for (commands) |*cmd| {
            const index = self.nodes.items.len;
            const node = Node.init(self.allocator, cmd);

            // Register names for lookup
            const name = node.name;
            if (name.len > 0) {
                // For create operations, register the created resource
                switch (node.node_type) {
                    .bond_create, .bridge_create => {
                        try self.name_to_index.put(name, index);
                    },
                    else => {},
                }
            }

            try self.nodes.append(node);
        }

        // Second pass: build dependencies
        for (self.nodes.items, 0..) |*node, i| {
            try self.buildDependencies(node, i);
        }
    }

    fn buildDependencies(self: *Self, node: *Node, node_index: usize) !void {
        switch (node.node_type) {
            .bond_member => {
                // Bond member depends on bond being created
                const bond_name = node.name;
                if (self.name_to_index.get(bond_name)) |bond_index| {
                    try node.dependencies.append(bond_index);
                    try self.nodes.items[bond_index].dependents.append(node_index);
                }
            },
            .bridge_member => {
                // Bridge member depends on bridge being created
                const bridge_name = node.name;
                if (self.name_to_index.get(bridge_name)) |bridge_index| {
                    try node.dependencies.append(bridge_index);
                    try self.nodes.items[bridge_index].dependents.append(node_index);
                }
            },
            .vlan_create => {
                // VLAN depends on parent interface (which might be a bond/bridge)
                const cmd = node.command;
                if (cmd.subject.vlan.parent) |parent| {
                    if (self.name_to_index.get(parent)) |parent_index| {
                        try node.dependencies.append(parent_index);
                        try self.nodes.items[parent_index].dependents.append(node_index);
                    }
                }
            },
            .address_add, .interface_config => {
                // Address/config depends on interface (which might be a bond/bridge/vlan)
                const iface_name = node.name;
                if (self.name_to_index.get(iface_name)) |iface_index| {
                    try node.dependencies.append(iface_index);
                    try self.nodes.items[iface_index].dependents.append(node_index);
                }
            },
            .route_add => {
                // Routes depend on all interface creations
                for (self.nodes.items, 0..) |other_node, j| {
                    switch (other_node.node_type) {
                        .bond_create, .bridge_create, .vlan_create => {
                            try node.dependencies.append(j);
                            try self.nodes.items[j].dependents.append(node_index);
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    /// Resolve dependencies and return commands in correct execution order
    pub fn resolve(self: *Self) ![]const *const parser.Command {
        var result = std.ArrayList(*const parser.Command).init(self.allocator);
        errdefer result.deinit();

        // Topological sort using Kahn's algorithm
        var in_degree = try self.allocator.alloc(usize, self.nodes.items.len);
        defer self.allocator.free(in_degree);

        // Calculate in-degrees
        for (self.nodes.items, 0..) |node, i| {
            in_degree[i] = node.dependencies.items.len;
        }

        // Queue of nodes with no dependencies
        var queue = std.ArrayList(usize).init(self.allocator);
        defer queue.deinit();

        for (0..self.nodes.items.len) |i| {
            if (in_degree[i] == 0) {
                try queue.append(i);
            }
        }

        var processed: usize = 0;

        while (queue.items.len > 0) {
            const index = queue.orderedRemove(0);
            const node = &self.nodes.items[index];

            try result.append(node.command);
            processed += 1;

            // Reduce in-degree of dependents
            for (node.dependents.items) |dep_index| {
                in_degree[dep_index] -= 1;
                if (in_degree[dep_index] == 0) {
                    try queue.append(dep_index);
                }
            }
        }

        if (processed != self.nodes.items.len) {
            return DependencyError.CircularDependency;
        }

        return result.toOwnedSlice();
    }
};

/// Resolve command dependencies
pub fn resolveCommands(commands: []const parser.Command, allocator: std.mem.Allocator) ![]const *const parser.Command {
    var resolver = Resolver.init(allocator);
    defer resolver.deinit();

    try resolver.addCommands(commands);
    return resolver.resolve();
}

// Tests

test "resolver init and deinit" {
    const allocator = std.testing.allocator;
    var resolver = Resolver.init(allocator);
    defer resolver.deinit();
}

test "empty commands resolve to empty" {
    const allocator = std.testing.allocator;
    const commands = [_]parser.Command{};

    const result = try resolveCommands(&commands, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
