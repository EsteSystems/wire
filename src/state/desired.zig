const std = @import("std");
const types = @import("types.zig");
const parser = @import("../syntax/parser.zig");
const loader = @import("../config/loader.zig");

/// Build desired state from parsed configuration commands
pub fn buildDesiredState(commands: []const parser.Command, allocator: std.mem.Allocator) !types.NetworkState {
    var state = types.NetworkState.init(allocator);
    errdefer state.deinit();

    for (commands) |cmd| {
        try processCommand(&state, &cmd);
    }

    state.timestamp = std.time.timestamp();
    return state;
}

fn processCommand(state: *types.NetworkState, cmd: *const parser.Command) !void {
    switch (cmd.subject) {
        .interface => |iface| try processInterfaceCommand(state, iface, cmd.action, cmd.attributes),
        .bond => |bond| try processBondCommand(state, bond, cmd.action, cmd.attributes),
        .bridge => |bridge| try processBridgeCommand(state, bridge, cmd.action, cmd.attributes),
        .vlan => |vlan| try processVlanCommand(state, vlan, cmd.action, cmd.attributes),
        .veth => |veth| try processVethCommand(state, veth, cmd.action),
        .route => |route| try processRouteCommand(state, route, cmd.action, cmd.attributes),
        .analyze => {}, // Not a state-modifying command
    }
}

fn processInterfaceCommand(
    state: *types.NetworkState,
    iface: parser.InterfaceSubject,
    action: parser.Action,
    attributes: []const parser.Attribute,
) !void {
    const name = iface.name orelse return;

    // Find or create interface state
    var iface_state = findOrCreateInterface(state, name);

    switch (action) {
        .set => |set| {
            if (std.mem.eql(u8, set.attr, "state")) {
                if (std.mem.eql(u8, set.value, "up")) {
                    iface_state.flags |= 1; // IFF_UP
                } else {
                    iface_state.flags &= ~@as(u32, 1);
                }
            } else if (std.mem.eql(u8, set.attr, "mtu")) {
                iface_state.mtu = std.fmt.parseInt(u32, set.value, 10) catch 1500;
            }
        },
        .add => |add| {
            // Add address
            if (add.value) |addr_str| {
                try addAddressToState(state, iface_state.index, name, addr_str);
            }
        },
        else => {},
    }

    // Process additional attributes
    for (attributes) |attr| {
        if (std.mem.eql(u8, attr.name, "mtu")) {
            if (attr.value) |val| {
                iface_state.mtu = std.fmt.parseInt(u32, val, 10) catch 1500;
            }
        } else if (std.mem.eql(u8, attr.name, "state")) {
            if (attr.value) |val| {
                if (std.mem.eql(u8, val, "up")) {
                    iface_state.flags |= 1;
                } else {
                    iface_state.flags &= ~@as(u32, 1);
                }
            }
        } else if (std.mem.eql(u8, attr.name, "address")) {
            if (attr.value) |addr_str| {
                try addAddressToState(state, iface_state.index, name, addr_str);
            }
        }
    }
}

fn processBondCommand(
    state: *types.NetworkState,
    bond: parser.BondSubject,
    action: parser.Action,
    attributes: []const parser.Attribute,
) !void {
    const name = bond.name orelse return;

    switch (action) {
        .create, .none => {
            var bond_state = types.BondState{
                .name = undefined,
                .name_len = 0,
                .index = generateVirtualIndex(state),
                .mode = .balance_rr,
                .miimon = 100,
                .updelay = 0,
                .downdelay = 0,
                .members = std.ArrayList(i32).init(state.allocator),
            };

            @memcpy(bond_state.name[0..name.len], name);
            bond_state.name_len = name.len;

            // Parse mode from attributes
            for (attributes) |attr| {
                if (std.mem.eql(u8, attr.name, "mode")) {
                    if (attr.value) |mode_str| {
                        bond_state.mode = parseBondMode(mode_str);
                    }
                }
            }

            try state.bonds.append(bond_state);

            // Also create corresponding interface
            _ = findOrCreateInterface(state, name);
        },
        .add => |add| {
            // Add member to bond
            if (add.value) |member_name| {
                if (findBond(state, name)) |bond_ptr| {
                    const member_iface = findOrCreateInterface(state, member_name);
                    try bond_ptr.members.append(member_iface.index);
                }
            }
        },
        .delete => {
            // Remove bond from desired state
            for (state.bonds.items, 0..) |b, i| {
                if (std.mem.eql(u8, b.getName(), name)) {
                    var removed = state.bonds.orderedRemove(i);
                    removed.deinit();
                    break;
                }
            }
        },
        else => {},
    }
}

fn processBridgeCommand(
    state: *types.NetworkState,
    bridge: parser.BridgeSubject,
    action: parser.Action,
    attributes: []const parser.Attribute,
) !void {
    _ = attributes;
    const name = bridge.name orelse return;

    switch (action) {
        .create, .none => {
            var bridge_state = types.BridgeState{
                .name = undefined,
                .name_len = 0,
                .index = generateVirtualIndex(state),
                .stp_enabled = false,
                .forward_delay = 15,
                .max_age = 20,
                .hello_time = 2,
                .ports = std.ArrayList(i32).init(state.allocator),
            };

            @memcpy(bridge_state.name[0..name.len], name);
            bridge_state.name_len = name.len;

            try state.bridges.append(bridge_state);

            // Also create corresponding interface
            _ = findOrCreateInterface(state, name);
        },
        .add => |add| {
            // Add port to bridge
            if (add.value) |port_name| {
                if (findBridge(state, name)) |bridge_ptr| {
                    const port_iface = findOrCreateInterface(state, port_name);
                    try bridge_ptr.ports.append(port_iface.index);
                }
            }
        },
        .delete => {
            // Remove bridge from desired state
            for (state.bridges.items, 0..) |b, i| {
                if (std.mem.eql(u8, b.getName(), name)) {
                    var removed = state.bridges.orderedRemove(i);
                    removed.deinit();
                    break;
                }
            }
        },
        else => {},
    }
}

fn processVlanCommand(
    state: *types.NetworkState,
    vlan: parser.VlanSubject,
    action: parser.Action,
    attributes: []const parser.Attribute,
) !void {
    _ = attributes;

    switch (action) {
        .create, .none => {
            const id = vlan.id orelse return;
            const parent = vlan.parent orelse return;

            var vlan_state = types.VlanState{
                .name = undefined,
                .name_len = 0,
                .index = generateVirtualIndex(state),
                .parent_index = 0,
                .vlan_id = id,
            };

            // Generate name: parent.id
            var name_buf: [32]u8 = undefined;
            const vlan_name = std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ parent, id }) catch return;

            @memcpy(vlan_state.name[0..vlan_name.len], vlan_name);
            vlan_state.name_len = vlan_name.len;

            // Get parent interface index
            const parent_iface = findOrCreateInterface(state, parent);
            vlan_state.parent_index = parent_iface.index;

            try state.vlans.append(vlan_state);

            // Also create corresponding interface
            _ = findOrCreateInterface(state, vlan_name);
        },
        .delete => {
            const id = vlan.id orelse return;
            const parent = vlan.parent orelse return;

            var name_buf: [32]u8 = undefined;
            const vlan_name = std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ parent, id }) catch return;

            for (state.vlans.items, 0..) |v, i| {
                if (std.mem.eql(u8, v.getName(), vlan_name)) {
                    _ = state.vlans.orderedRemove(i);
                    break;
                }
            }
        },
        else => {},
    }
}

fn processVethCommand(
    state: *types.NetworkState,
    veth: parser.VethSubject,
    action: parser.Action,
) !void {
    switch (action) {
        .create, .none => {
            const name = veth.name orelse return;
            const peer = veth.peer orelse return;

            // Create veth interface
            const veth_iface = findOrCreateInterface(state, name);
            veth_iface.link_type = .veth;

            // Create peer interface
            const peer_iface = findOrCreateInterface(state, peer);
            peer_iface.link_type = .veth;

            // Create veth state to track the pair relationship
            var veth_state = types.VethState{
                .name = undefined,
                .name_len = 0,
                .index = veth_iface.index,
                .peer_index = peer_iface.index,
                .peer_netns_id = null,
            };

            @memcpy(veth_state.name[0..name.len], name);
            veth_state.name_len = name.len;

            try state.veths.append(veth_state);
        },
        .delete => {
            const name = veth.name orelse return;

            // Remove veth from state
            for (state.veths.items, 0..) |v, i| {
                if (std.mem.eql(u8, v.getName(), name)) {
                    _ = state.veths.orderedRemove(i);
                    break;
                }
            }
        },
        else => {},
    }
}

fn processRouteCommand(
    state: *types.NetworkState,
    route: parser.RouteSubject,
    action: parser.Action,
    attributes: []const parser.Attribute,
) !void {
    switch (action) {
        .add, .none => {
            var route_state = types.RouteState{
                .family = 2, // AF_INET
                .dst = undefined,
                .dst_len = 0,
                .gateway = undefined,
                .has_gateway = false,
                .oif = 0,
                .priority = 0,
                .table = 254, // RT_TABLE_MAIN
                .protocol = 4, // RTPROT_STATIC
                .scope = 0, // RT_SCOPE_UNIVERSE
                .route_type = 1, // RTN_UNICAST
            };

            @memset(&route_state.dst, 0);
            @memset(&route_state.gateway, 0);

            // Parse destination from subject or action
            const dst_str = route.destination orelse if (action == .add) action.add.value else null;
            if (dst_str) |dst| {
                if (!std.mem.eql(u8, dst, "default")) {
                    // Parse IP/prefix
                    if (parseIPv4Prefix(dst)) |parsed| {
                        @memcpy(route_state.dst[0..4], &parsed.addr);
                        route_state.dst_len = parsed.prefix;
                    }
                }
            }

            // Parse attributes
            for (attributes) |attr| {
                if (std.mem.eql(u8, attr.name, "via")) {
                    if (attr.value) |gw| {
                        if (parseIPv4(gw)) |gw_addr| {
                            @memcpy(route_state.gateway[0..4], &gw_addr);
                            route_state.has_gateway = true;
                        }
                    }
                } else if (std.mem.eql(u8, attr.name, "dev")) {
                    if (attr.value) |dev| {
                        const iface = findOrCreateInterface(state, dev);
                        route_state.oif = @intCast(iface.index);
                    }
                } else if (std.mem.eql(u8, attr.name, "metric")) {
                    if (attr.value) |m| {
                        route_state.priority = std.fmt.parseInt(u32, m, 10) catch 0;
                    }
                }
            }

            try state.routes.append(route_state);
        },
        .del => {
            // Mark route for removal (in diff, we compare against live)
        },
        else => {},
    }
}

// Helper functions

fn findOrCreateInterface(state: *types.NetworkState, name: []const u8) *types.InterfaceState {
    // Find existing
    for (state.interfaces.items) |*iface| {
        if (std.mem.eql(u8, iface.getName(), name)) {
            return iface;
        }
    }

    // Create new
    var iface_state = types.InterfaceState{
        .name = undefined,
        .name_len = 0,
        .index = generateVirtualIndex(state),
        .flags = 0,
        .mtu = 1500,
        .mac = undefined,
        .has_mac = false,
        .operstate = 0,
        .link_type = .other,
        .master_index = null,
    };

    @memcpy(iface_state.name[0..name.len], name);
    iface_state.name_len = name.len;
    @memset(&iface_state.mac, 0);

    state.interfaces.append(iface_state) catch return &state.interfaces.items[0];
    return &state.interfaces.items[state.interfaces.items.len - 1];
}

fn findBond(state: *types.NetworkState, name: []const u8) ?*types.BondState {
    for (state.bonds.items) |*bond| {
        if (std.mem.eql(u8, bond.getName(), name)) {
            return bond;
        }
    }
    return null;
}

fn findBridge(state: *types.NetworkState, name: []const u8) ?*types.BridgeState {
    for (state.bridges.items) |*bridge| {
        if (std.mem.eql(u8, bridge.getName(), name)) {
            return bridge;
        }
    }
    return null;
}

fn generateVirtualIndex(state: *types.NetworkState) i32 {
    // Generate a high index for desired state objects
    // Real indices come from the kernel
    var max_index: i32 = 1000;
    for (state.interfaces.items) |iface| {
        if (iface.index >= max_index) {
            max_index = iface.index + 1;
        }
    }
    return max_index;
}

fn addAddressToState(state: *types.NetworkState, iface_index: i32, iface_name: []const u8, addr_str: []const u8) !void {
    if (parseIPv4Prefix(addr_str)) |parsed| {
        var addr_state = types.AddressState{
            .interface_index = iface_index,
            .family = 2, // AF_INET
            .address = undefined,
            .prefix_len = parsed.prefix,
            .scope = 0,
            .flags = 0,
        };

        @memset(&addr_state.address, 0);
        @memcpy(addr_state.address[0..4], &parsed.addr);

        // Store interface name for lookup during reconciliation
        @memset(&addr_state.interface_name, 0);
        const name_len = @min(iface_name.len, addr_state.interface_name.len);
        @memcpy(addr_state.interface_name[0..name_len], iface_name[0..name_len]);
        addr_state.interface_name_len = name_len;

        try state.addresses.append(addr_state);
    }
}

fn parseBondMode(mode_str: []const u8) types.BondState.BondMode {
    if (std.mem.eql(u8, mode_str, "balance-rr") or std.mem.eql(u8, mode_str, "0")) return .balance_rr;
    if (std.mem.eql(u8, mode_str, "active-backup") or std.mem.eql(u8, mode_str, "1")) return .active_backup;
    if (std.mem.eql(u8, mode_str, "balance-xor") or std.mem.eql(u8, mode_str, "2")) return .balance_xor;
    if (std.mem.eql(u8, mode_str, "broadcast") or std.mem.eql(u8, mode_str, "3")) return .broadcast;
    if (std.mem.eql(u8, mode_str, "802.3ad") or std.mem.eql(u8, mode_str, "4")) return .@"802.3ad";
    if (std.mem.eql(u8, mode_str, "balance-tlb") or std.mem.eql(u8, mode_str, "5")) return .balance_tlb;
    if (std.mem.eql(u8, mode_str, "balance-alb") or std.mem.eql(u8, mode_str, "6")) return .balance_alb;
    return .balance_rr;
}

const IPv4Prefix = struct {
    addr: [4]u8,
    prefix: u8,
};

fn parseIPv4Prefix(str: []const u8) ?IPv4Prefix {
    var result = IPv4Prefix{ .addr = undefined, .prefix = 32 };

    // Split on /
    if (std.mem.indexOfScalar(u8, str, '/')) |slash| {
        const ip_part = str[0..slash];
        const prefix_part = str[slash + 1 ..];

        result.prefix = std.fmt.parseInt(u8, prefix_part, 10) catch return null;

        if (parseIPv4(ip_part)) |addr| {
            result.addr = addr;
            return result;
        }
    } else {
        if (parseIPv4(str)) |addr| {
            result.addr = addr;
            return result;
        }
    }

    return null;
}

fn parseIPv4(str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet: usize = 0;
    var value: u8 = 0;
    var has_digit = false;

    for (str) |c| {
        if (c == '.') {
            if (!has_digit or octet >= 3) return null;
            result[octet] = value;
            octet += 1;
            value = 0;
            has_digit = false;
        } else if (c >= '0' and c <= '9') {
            const digit = c - '0';
            const new_value = @as(u16, value) * 10 + digit;
            if (new_value > 255) return null;
            value = @intCast(new_value);
            has_digit = true;
        } else {
            return null;
        }
    }

    if (!has_digit or octet != 3) return null;
    result[octet] = value;

    return result;
}

// Tests

test "parse ipv4 prefix" {
    const result = parseIPv4Prefix("10.0.0.1/24");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 24), result.?.prefix);
    try std.testing.expectEqual(@as(u8, 10), result.?.addr[0]);
}

test "parse ipv4 address" {
    const result = parseIPv4("192.168.1.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 192), result.?[0]);
    try std.testing.expectEqual(@as(u8, 168), result.?[1]);
}
