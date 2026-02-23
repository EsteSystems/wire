const std = @import("std");

/// Unified state types for network configuration
/// These types represent both desired and live state

/// Interface state
pub const InterfaceState = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    flags: u32,
    mtu: u32,
    mac: [6]u8,
    has_mac: bool,
    operstate: u8,
    link_type: LinkType,
    master_index: ?i32, // For bond/bridge members

    pub const LinkType = enum {
        physical,
        bond,
        bridge,
        vlan,
        veth,
        tap,
        tun,
        loopback,
        other,
    };

    pub fn getName(self: *const InterfaceState) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isUp(self: *const InterfaceState) bool {
        return (self.flags & (1 << 0)) != 0; // IFF_UP
    }

    pub fn hasCarrier(self: *const InterfaceState) bool {
        return (self.flags & (1 << 16)) != 0; // IFF_LOWER_UP
    }
};

/// Address state
pub const AddressState = struct {
    interface_index: i32,
    interface_name: [16]u8 = undefined, // Interface name for lookup
    interface_name_len: usize = 0,
    family: u8, // AF_INET or AF_INET6
    address: [16]u8, // Enough for IPv6
    prefix_len: u8,
    scope: u8,
    flags: u32,

    pub fn isIPv4(self: *const AddressState) bool {
        return self.family == 2; // AF_INET
    }

    pub fn isIPv6(self: *const AddressState) bool {
        return self.family == 10; // AF_INET6
    }

    pub fn getInterfaceName(self: *const AddressState) []const u8 {
        return self.interface_name[0..self.interface_name_len];
    }
};

/// Route state
pub const RouteState = struct {
    family: u8,
    dst: [16]u8,
    dst_len: u8,
    gateway: [16]u8,
    has_gateway: bool,
    oif: u32, // Output interface index
    priority: u32,
    table: u32,
    protocol: u8,
    scope: u8,
    route_type: u8,

    pub fn isDefault(self: *const RouteState) bool {
        return self.dst_len == 0;
    }
};

/// Bond state
pub const BondState = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    mode: BondMode,
    miimon: u32,
    updelay: u32,
    downdelay: u32,
    members: std.array_list.Managed(i32),

    pub const BondMode = enum(u8) {
        balance_rr = 0,
        active_backup = 1,
        balance_xor = 2,
        broadcast = 3,
        @"802.3ad" = 4,
        balance_tlb = 5,
        balance_alb = 6,
    };

    pub fn getName(self: *const BondState) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn deinit(self: *BondState) void {
        self.members.deinit();
    }
};

/// Bridge state
pub const BridgeState = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    stp_enabled: bool,
    forward_delay: u32,
    max_age: u32,
    hello_time: u32,
    ports: std.array_list.Managed(i32),

    pub fn getName(self: *const BridgeState) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn deinit(self: *BridgeState) void {
        self.ports.deinit();
    }
};

/// VLAN state
pub const VlanState = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    parent_index: i32,
    vlan_id: u16,

    pub fn getName(self: *const VlanState) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Veth pair state
pub const VethState = struct {
    name: [16]u8,
    name_len: usize,
    index: i32,
    peer_index: i32, // Index of the peer veth interface
    peer_netns_id: ?i32, // Network namespace ID of peer (null if same namespace)

    pub fn getName(self: *const VethState) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Complete network state snapshot
pub const NetworkState = struct {
    allocator: std.mem.Allocator,
    interfaces: std.array_list.Managed(InterfaceState),
    addresses: std.array_list.Managed(AddressState),
    routes: std.array_list.Managed(RouteState),
    bonds: std.array_list.Managed(BondState),
    bridges: std.array_list.Managed(BridgeState),
    vlans: std.array_list.Managed(VlanState),
    veths: std.array_list.Managed(VethState),
    timestamp: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .interfaces = std.array_list.Managed(InterfaceState).init(allocator),
            .addresses = std.array_list.Managed(AddressState).init(allocator),
            .routes = std.array_list.Managed(RouteState).init(allocator),
            .bonds = std.array_list.Managed(BondState).init(allocator),
            .bridges = std.array_list.Managed(BridgeState).init(allocator),
            .vlans = std.array_list.Managed(VlanState).init(allocator),
            .veths = std.array_list.Managed(VethState).init(allocator),
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.interfaces.deinit();
        self.addresses.deinit();
        self.routes.deinit();

        for (self.bonds.items) |*bond| {
            bond.deinit();
        }
        self.bonds.deinit();

        for (self.bridges.items) |*bridge| {
            bridge.deinit();
        }
        self.bridges.deinit();

        self.vlans.deinit();
        self.veths.deinit();
    }

    /// Find interface by name
    pub fn findInterface(self: *const Self, name: []const u8) ?*const InterfaceState {
        for (self.interfaces.items) |*iface| {
            if (std.mem.eql(u8, iface.getName(), name)) {
                return iface;
            }
        }
        return null;
    }

    /// Find interface by index
    pub fn findInterfaceByIndex(self: *const Self, index: i32) ?*const InterfaceState {
        for (self.interfaces.items) |*iface| {
            if (iface.index == index) {
                return iface;
            }
        }
        return null;
    }

    /// Get addresses for an interface
    pub fn getAddressesForInterface(self: *const Self, index: i32) []const AddressState {
        var start: usize = 0;
        var count: usize = 0;

        for (self.addresses.items, 0..) |addr, i| {
            if (addr.interface_index == index) {
                if (count == 0) start = i;
                count += 1;
            }
        }

        if (count == 0) return &[_]AddressState{};
        return self.addresses.items[start .. start + count];
    }

    /// Find veth state by interface index
    pub fn findVeth(self: *const Self, index: i32) ?*const VethState {
        for (self.veths.items) |*veth| {
            if (veth.index == index) {
                return veth;
            }
        }
        return null;
    }

    /// Get veth peer interface (returns peer interface if exists in same namespace)
    pub fn getVethPeer(self: *const Self, index: i32) ?*const InterfaceState {
        if (self.findVeth(index)) |veth| {
            // Only return peer if it's in the same namespace
            if (veth.peer_netns_id == null) {
                return self.findInterfaceByIndex(veth.peer_index);
            }
        }
        return null;
    }
};

/// State change/diff types
pub const StateChange = union(enum) {
    interface_add: InterfaceState,
    interface_remove: []const u8, // name
    interface_modify: struct {
        name: []const u8,
        old: InterfaceState,
        new: InterfaceState,
    },
    address_add: AddressState,
    address_remove: AddressState,
    route_add: RouteState,
    route_remove: RouteState,
    bond_add: BondState,
    bond_remove: []const u8,
    bridge_add: BridgeState,
    bridge_remove: []const u8,
    vlan_add: VlanState,
    vlan_remove: []const u8,
};

/// Result of comparing two states
pub const StateDiff = struct {
    changes: std.array_list.Managed(StateChange),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .changes = std.array_list.Managed(StateChange).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.changes.deinit();
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.changes.items.len == 0;
    }
};

// Tests

test "network state init and deinit" {
    const allocator = std.testing.allocator;
    var state = NetworkState.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.interfaces.items.len == 0);
    try std.testing.expect(state.timestamp > 0);
}
