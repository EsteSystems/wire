const std = @import("std");
const types = @import("types.zig");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");

/// Query the live network state from the kernel via netlink
pub fn queryLiveState(allocator: std.mem.Allocator) !types.NetworkState {
    var state = types.NetworkState.init(allocator);
    errdefer state.deinit();

    // Query interfaces
    try queryInterfaces(&state);

    // Query addresses
    try queryAddresses(&state);

    // Query routes
    try queryRoutes(&state);

    // Update timestamp
    state.timestamp = std.time.timestamp();

    return state;
}

fn queryInterfaces(state: *types.NetworkState) !void {
    const interfaces = try netlink_interface.getInterfaces(state.allocator);
    defer state.allocator.free(interfaces);

    for (interfaces) |iface| {
        var iface_state = types.InterfaceState{
            .name = undefined,
            .name_len = 0,
            .index = iface.index,
            .flags = iface.flags,
            .mtu = iface.mtu,
            .mac = iface.mac,
            .has_mac = iface.has_mac,
            .operstate = iface.operstate,
            .link_type = determineLinkType(iface.flags, iface.getName()),
            .master_index = iface.master_index,
        };

        // Copy name
        const name = iface.getName();
        @memcpy(iface_state.name[0..name.len], name);
        iface_state.name_len = name.len;

        try state.interfaces.append(iface_state);
    }
}

fn determineLinkType(flags: u32, name: []const u8) types.InterfaceState.LinkType {
    // Check for loopback
    if ((flags & (1 << 3)) != 0) return .loopback; // IFF_LOOPBACK

    // Heuristic based on name patterns
    if (std.mem.startsWith(u8, name, "bond")) return .bond;
    if (std.mem.startsWith(u8, name, "br") or std.mem.startsWith(u8, name, "virbr")) return .bridge;
    if (std.mem.indexOf(u8, name, ".") != null) return .vlan;
    if (std.mem.startsWith(u8, name, "veth")) return .veth;
    if (std.mem.startsWith(u8, name, "tap") or std.mem.startsWith(u8, name, "vnet")) return .tap;
    if (std.mem.startsWith(u8, name, "tun")) return .tun;

    // Check for physical interface patterns
    if (std.mem.startsWith(u8, name, "eth") or
        std.mem.startsWith(u8, name, "en") or
        std.mem.startsWith(u8, name, "em"))
    {
        return .physical;
    }

    return .other;
}

fn queryAddresses(state: *types.NetworkState) !void {
    const addresses = try netlink_address.getAddresses(state.allocator);
    defer state.allocator.free(addresses);

    for (addresses) |addr| {
        var addr_state = types.AddressState{
            .interface_index = @intCast(addr.index),
            .family = addr.family,
            .address = undefined,
            .prefix_len = addr.prefixlen,
            .scope = addr.scope,
            .flags = 0, // Not available from netlink address query
        };

        // Copy address
        @memset(&addr_state.address, 0);
        if (addr.family == 2) { // AF_INET
            @memcpy(addr_state.address[0..4], addr.address[0..4]);
        } else if (addr.family == 10) { // AF_INET6
            @memcpy(addr_state.address[0..16], addr.address[0..16]);
        }

        try state.addresses.append(addr_state);
    }
}

fn queryRoutes(state: *types.NetworkState) !void {
    const routes = try netlink_route.getRoutes(state.allocator);
    defer state.allocator.free(routes);

    for (routes) |route| {
        // Skip non-unicast routes
        if (route.route_type != 1) continue;

        var route_state = types.RouteState{
            .family = route.family,
            .dst = undefined,
            .dst_len = route.dst_len,
            .gateway = undefined,
            .has_gateway = route.has_gateway,
            .oif = route.oif,
            .priority = route.priority,
            .table = route.table,
            .protocol = route.protocol,
            .scope = route.scope,
            .route_type = route.route_type,
        };

        // Copy destination
        @memset(&route_state.dst, 0);
        if (route.family == 2) {
            @memcpy(route_state.dst[0..4], route.dst[0..4]);
        } else if (route.family == 10) {
            @memcpy(route_state.dst[0..16], route.dst[0..16]);
        }

        // Copy gateway
        @memset(&route_state.gateway, 0);
        if (route.has_gateway) {
            if (route.family == 2) {
                @memcpy(route_state.gateway[0..4], route.gateway[0..4]);
            } else if (route.family == 10) {
                @memcpy(route_state.gateway[0..16], route.gateway[0..16]);
            }
        }

        try state.routes.append(route_state);
    }
}

/// Refresh a specific part of the state
pub const RefreshTarget = enum {
    interfaces,
    addresses,
    routes,
    all,
};

pub fn refreshState(state: *types.NetworkState, target: RefreshTarget) !void {
    switch (target) {
        .interfaces => {
            state.interfaces.clearRetainingCapacity();
            try queryInterfaces(state);
        },
        .addresses => {
            state.addresses.clearRetainingCapacity();
            try queryAddresses(state);
        },
        .routes => {
            state.routes.clearRetainingCapacity();
            try queryRoutes(state);
        },
        .all => {
            state.interfaces.clearRetainingCapacity();
            state.addresses.clearRetainingCapacity();
            state.routes.clearRetainingCapacity();
            try queryInterfaces(state);
            try queryAddresses(state);
            try queryRoutes(state);
        },
    }
    state.timestamp = std.time.timestamp();
}

// Tests

test "query live state structure" {
    // This test just verifies the module compiles
    // Actual live state query requires root privileges
}
