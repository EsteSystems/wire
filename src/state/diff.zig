const std = @import("std");
const types = @import("types.zig");

/// Compare desired state against live state and return differences
/// Returns changes needed to make live state match desired state
pub fn compare(desired: *const types.NetworkState, live: *const types.NetworkState, allocator: std.mem.Allocator) !types.StateDiff {
    var diff = types.StateDiff.init(allocator);
    errdefer diff.deinit();

    // Compare bonds (must be created before members can join)
    try compareBonds(desired, live, &diff);

    // Compare bridges
    try compareBridges(desired, live, &diff);

    // Compare VLANs
    try compareVlans(desired, live, &diff);

    // Compare interfaces (state, mtu)
    try compareInterfaces(desired, live, &diff);

    // Compare addresses
    try compareAddresses(desired, live, &diff);

    // Compare routes
    try compareRoutes(desired, live, &diff);

    return diff;
}

fn compareBonds(desired: *const types.NetworkState, live: *const types.NetworkState, diff: *types.StateDiff) !void {
    // Find bonds to add
    for (desired.bonds.items) |d_bond| {
        var found = false;
        for (live.bonds.items) |l_bond| {
            if (std.mem.eql(u8, d_bond.getName(), l_bond.getName())) {
                found = true;
                // TODO: Compare bond parameters and generate modify change
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .bond_add = d_bond });
        }
    }

    // Find bonds to remove (in live but not in desired)
    for (live.bonds.items) |l_bond| {
        var found = false;
        for (desired.bonds.items) |d_bond| {
            if (std.mem.eql(u8, l_bond.getName(), d_bond.getName())) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .bond_remove = l_bond.getName() });
        }
    }
}

fn compareBridges(desired: *const types.NetworkState, live: *const types.NetworkState, diff: *types.StateDiff) !void {
    // Find bridges to add
    for (desired.bridges.items) |d_bridge| {
        var found = false;
        for (live.bridges.items) |l_bridge| {
            if (std.mem.eql(u8, d_bridge.getName(), l_bridge.getName())) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .bridge_add = d_bridge });
        }
    }

    // Find bridges to remove
    for (live.bridges.items) |l_bridge| {
        var found = false;
        for (desired.bridges.items) |d_bridge| {
            if (std.mem.eql(u8, l_bridge.getName(), d_bridge.getName())) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .bridge_remove = l_bridge.getName() });
        }
    }
}

fn compareVlans(desired: *const types.NetworkState, live: *const types.NetworkState, diff: *types.StateDiff) !void {
    // Find VLANs to add
    for (desired.vlans.items) |d_vlan| {
        var found = false;
        for (live.vlans.items) |l_vlan| {
            if (std.mem.eql(u8, d_vlan.getName(), l_vlan.getName())) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .vlan_add = d_vlan });
        }
    }

    // Find VLANs to remove
    for (live.vlans.items) |l_vlan| {
        var found = false;
        for (desired.vlans.items) |d_vlan| {
            if (std.mem.eql(u8, l_vlan.getName(), d_vlan.getName())) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .vlan_remove = l_vlan.getName() });
        }
    }
}

fn compareInterfaces(desired: *const types.NetworkState, live: *const types.NetworkState, diff: *types.StateDiff) !void {
    for (desired.interfaces.items) |d_iface| {
        // Find matching live interface
        for (live.interfaces.items) |l_iface| {
            if (std.mem.eql(u8, d_iface.getName(), l_iface.getName())) {
                // Check for differences
                const d_up = d_iface.isUp();
                const l_up = l_iface.isUp();

                if (d_up != l_up or d_iface.mtu != l_iface.mtu) {
                    try diff.changes.append(.{
                        .interface_modify = .{
                            .name = d_iface.getName(),
                            .old = l_iface,
                            .new = d_iface,
                        },
                    });
                }
                break;
            }
        }
    }
}

fn compareAddresses(desired: *const types.NetworkState, live: *const types.NetworkState, diff: *types.StateDiff) !void {
    // Find addresses to add
    for (desired.addresses.items) |d_addr| {
        var found = false;
        for (live.addresses.items) |l_addr| {
            if (addressesEqual(&d_addr, &l_addr)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .address_add = d_addr });
        }
    }

    // Note: We don't remove addresses not in desired state by default
    // This is a policy decision - some addresses may be added by DHCP, etc.
}

fn compareRoutes(desired: *const types.NetworkState, live: *const types.NetworkState, diff: *types.StateDiff) !void {
    // Find routes to add
    for (desired.routes.items) |d_route| {
        var found = false;
        for (live.routes.items) |l_route| {
            if (routesEqual(&d_route, &l_route)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diff.changes.append(.{ .route_add = d_route });
        }
    }

    // Note: Similar to addresses, we don't remove routes not in desired state
}

fn addressesEqual(a: *const types.AddressState, b: *const types.AddressState) bool {
    if (a.family != b.family) return false;
    if (a.prefix_len != b.prefix_len) return false;

    const len: usize = if (a.family == 2) 4 else 16;
    return std.mem.eql(u8, a.address[0..len], b.address[0..len]);
}

fn routesEqual(a: *const types.RouteState, b: *const types.RouteState) bool {
    if (a.family != b.family) return false;
    if (a.dst_len != b.dst_len) return false;

    const len: usize = if (a.family == 2) 4 else 16;
    if (!std.mem.eql(u8, a.dst[0..len], b.dst[0..len])) return false;

    // For default routes or same destination, check gateway
    if (a.has_gateway != b.has_gateway) return false;
    if (a.has_gateway) {
        if (!std.mem.eql(u8, a.gateway[0..len], b.gateway[0..len])) return false;
    }

    return true;
}

/// Format the diff for human-readable output
pub fn formatDiff(diff: *const types.StateDiff, writer: anytype) !void {
    if (diff.isEmpty()) {
        try writer.print("No changes detected - state is in sync\n", .{});
        return;
    }

    try writer.print("State differences ({d} changes):\n", .{diff.changes.items.len});
    try writer.print("=================================\n\n", .{});

    for (diff.changes.items) |change| {
        switch (change) {
            .bond_add => |bond| {
                try writer.print("+ Bond: {s} (mode: {s})\n", .{ bond.getName(), @tagName(bond.mode) });
            },
            .bond_remove => |name| {
                try writer.print("- Bond: {s}\n", .{name});
            },
            .bridge_add => |bridge| {
                try writer.print("+ Bridge: {s}\n", .{bridge.getName()});
            },
            .bridge_remove => |name| {
                try writer.print("- Bridge: {s}\n", .{name});
            },
            .vlan_add => |vlan| {
                try writer.print("+ VLAN: {s} (id: {d})\n", .{ vlan.getName(), vlan.vlan_id });
            },
            .vlan_remove => |name| {
                try writer.print("- VLAN: {s}\n", .{name});
            },
            .interface_modify => |mod| {
                try writer.print("~ Interface: {s}\n", .{mod.name});
                if (mod.old.isUp() != mod.new.isUp()) {
                    try writer.print("    state: {s} -> {s}\n", .{
                        if (mod.old.isUp()) "up" else "down",
                        if (mod.new.isUp()) "up" else "down",
                    });
                }
                if (mod.old.mtu != mod.new.mtu) {
                    try writer.print("    mtu: {d} -> {d}\n", .{ mod.old.mtu, mod.new.mtu });
                }
            },
            .address_add => |addr| {
                var buf: [64]u8 = undefined;
                const addr_str = formatAddress(&addr, &buf) catch "?";
                try writer.print("+ Address: {s}\n", .{addr_str});
            },
            .address_remove => |addr| {
                var buf: [64]u8 = undefined;
                const addr_str = formatAddress(&addr, &buf) catch "?";
                try writer.print("- Address: {s}\n", .{addr_str});
            },
            .route_add => |route| {
                var buf: [128]u8 = undefined;
                const route_str = formatRoute(&route, &buf) catch "?";
                try writer.print("+ Route: {s}\n", .{route_str});
            },
            .route_remove => |route| {
                var buf: [128]u8 = undefined;
                const route_str = formatRoute(&route, &buf) catch "?";
                try writer.print("- Route: {s}\n", .{route_str});
            },
            else => {},
        }
    }
}

fn formatAddress(addr: *const types.AddressState, buf: []u8) ![]const u8 {
    if (addr.family == 2) {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
            addr.address[0],
            addr.address[1],
            addr.address[2],
            addr.address[3],
            addr.prefix_len,
        });
    }
    return "ipv6";
}

fn formatRoute(route: *const types.RouteState, buf: []u8) ![]const u8 {
    var offset: usize = 0;

    // Destination
    if (route.dst_len == 0) {
        const s = "default";
        @memcpy(buf[offset .. offset + s.len], s);
        offset += s.len;
    } else {
        const dst_str = try std.fmt.bufPrint(buf[offset..], "{d}.{d}.{d}.{d}/{d}", .{
            route.dst[0],
            route.dst[1],
            route.dst[2],
            route.dst[3],
            route.dst_len,
        });
        offset += dst_str.len;
    }

    // Gateway
    if (route.has_gateway) {
        const via = " via ";
        @memcpy(buf[offset .. offset + via.len], via);
        offset += via.len;

        const gw_str = try std.fmt.bufPrint(buf[offset..], "{d}.{d}.{d}.{d}", .{
            route.gateway[0],
            route.gateway[1],
            route.gateway[2],
            route.gateway[3],
        });
        offset += gw_str.len;
    }

    return buf[0..offset];
}

// Tests

test "empty diff for identical states" {
    const allocator = std.testing.allocator;

    var desired = types.NetworkState.init(allocator);
    defer desired.deinit();

    var live = types.NetworkState.init(allocator);
    defer live.deinit();

    var diff = try compare(&desired, &live, allocator);
    defer diff.deinit();

    try std.testing.expect(diff.isEmpty());
}
