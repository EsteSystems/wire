const std = @import("std");
const bond = @import("../src/netlink/bond.zig");
const bridge = @import("../src/netlink/bridge.zig");
const vlan = @import("../src/netlink/vlan.zig");
const veth = @import("../src/netlink/veth.zig");
const interface = @import("../src/netlink/interface.zig");
const address = @import("../src/netlink/address.zig");
const route = @import("../src/netlink/route.zig");

// Integration tests for wire netlink operations.
// Requirements:
//   - Linux (x86_64)
//   - Root privileges (CAP_NET_ADMIN)
//   - No real NICs are modified; tests use veth pairs for isolation
//
// Run with: zig build test-integration (on Linux VM)

/// Create a veth pair for testing and return the names
fn createTestVeth(allocator: std.mem.Allocator, suffix: []const u8) !struct { a: []const u8, b: []const u8 } {
    var name_a_buf: [16]u8 = undefined;
    var name_b_buf: [16]u8 = undefined;
    const name_a = std.fmt.bufPrint(&name_a_buf, "wt-a-{s}", .{suffix}) catch return error.NameTooLong;
    const name_b = std.fmt.bufPrint(&name_b_buf, "wt-b-{s}", .{suffix}) catch return error.NameTooLong;

    // Delete any leftover test interfaces
    veth.deleteVeth(name_a) catch {};

    // Create fresh veth pair
    try veth.createVethPair(name_a, name_b);

    // Return allocated copies
    const a_copy = try allocator.dupe(u8, name_a);
    const b_copy = try allocator.dupe(u8, name_b);
    return .{ .a = a_copy, .b = b_copy };
}

/// Clean up a veth pair (deleting one end removes both)
fn cleanupTestVeth(name: []const u8) void {
    veth.deleteVeth(name) catch {};
}

// === Bond Integration Tests ===

test "integration: bond create and list" {
    const allocator = std.testing.allocator;

    // Create a bond
    bond.createBond("wt-bond0", .active_backup) catch |err| {
        // If we get PermissionDenied, skip (not running as root)
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer bond.deleteBond("wt-bond0") catch {};

    // List bonds and verify ours is there
    const bonds = try bond.getBonds(allocator);
    defer allocator.free(bonds);

    var found = false;
    for (bonds) |b| {
        if (std.mem.eql(u8, b.getName(), "wt-bond0")) {
            found = true;
            try std.testing.expectEqual(bond.BondMode.active_backup, b.mode);
        }
    }
    try std.testing.expect(found);
}

test "integration: bond modify" {
    const allocator = std.testing.allocator;

    bond.createBond("wt-bond1", .balance_rr) catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer bond.deleteBond("wt-bond1") catch {};

    // Modify to 802.3ad with options
    try bond.modifyBond("wt-bond1", .{
        .mode = .@"802.3ad",
        .miimon = 200,
        .lacp_rate = .fast,
        .xmit_hash_policy = .layer3_4,
    });

    // Verify
    const b = try bond.getBondByName(allocator, "wt-bond1");
    try std.testing.expect(b != null);
    try std.testing.expectEqual(bond.BondMode.@"802.3ad", b.?.mode);
}

test "integration: bond member add/remove" {
    const allocator = std.testing.allocator;

    // Create veth pair for members
    const veths = createTestVeth(allocator, "bm") catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer allocator.free(veths.a);
    defer allocator.free(veths.b);
    defer cleanupTestVeth(veths.a);

    // Create bond
    bond.createBond("wt-bond2", .active_backup) catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer bond.deleteBond("wt-bond2") catch {};

    // Add member
    try bond.addBondMember("wt-bond2", veths.a);

    // Verify member is enslaved
    const iface = try interface.getInterfaceByName(allocator, veths.a);
    try std.testing.expect(iface != null);
    try std.testing.expect(iface.?.master_index != null);

    // Remove member
    try bond.removeBondMember(veths.a);

    // Verify member is free
    const iface2 = try interface.getInterfaceByName(allocator, veths.a);
    try std.testing.expect(iface2 != null);
    try std.testing.expect(iface2.?.master_index == null);
}

// === Bridge Integration Tests ===

test "integration: bridge create with STP" {
    const allocator = std.testing.allocator;

    bridge.createBridge("wt-br0") catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer bridge.deleteBridge("wt-br0") catch {};

    // Enable STP
    try bridge.setBridgeStp("wt-br0", true);

    // Verify bridge exists
    const iface = try interface.verifyInterfaceExists(allocator, "wt-br0");
    try std.testing.expect(iface.getLinkKind() != null);
    try std.testing.expectEqualStrings("bridge", iface.getLinkKind().?);
}

test "integration: bridge member management" {
    const allocator = std.testing.allocator;

    const veths = createTestVeth(allocator, "br") catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer allocator.free(veths.a);
    defer allocator.free(veths.b);
    defer cleanupTestVeth(veths.a);

    bridge.createBridge("wt-br1") catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer bridge.deleteBridge("wt-br1") catch {};

    // Add member
    try bridge.addBridgeMember("wt-br1", veths.a);

    // Verify
    const iface = try interface.getInterfaceByName(allocator, veths.a);
    try std.testing.expect(iface != null);
    try std.testing.expect(iface.?.master_index != null);

    // Remove member
    try bridge.removeBridgeMember(veths.a);
}

// === VLAN Integration Tests ===

test "integration: vlan create and list" {
    const allocator = std.testing.allocator;

    const veths = createTestVeth(allocator, "vl") catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer allocator.free(veths.a);
    defer allocator.free(veths.b);
    defer cleanupTestVeth(veths.a);

    // Create VLAN on veth
    vlan.createVlan(veths.a, 100) catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };

    // Defer delete using a known name pattern
    var vlan_name_buf: [32]u8 = undefined;
    const vlan_name = std.fmt.bufPrint(&vlan_name_buf, "{s}.100", .{veths.a}) catch unreachable;
    defer vlan.deleteVlan(vlan_name) catch {};

    // List VLANs
    const vlans = try vlan.getVlans(allocator);
    defer allocator.free(vlans);

    var found = false;
    for (vlans) |v| {
        if (v.vlan_id == 100) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

// === Route Integration Tests ===

test "integration: route add and delete" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Add a route to a blackhole destination (safe, doesn't affect real traffic)
    const dst = [4]u8{ 198, 51, 100, 0 }; // 198.51.100.0/24 (TEST-NET-2)
    route.addRoute(
        2, // AF_INET
        &dst,
        24,
        null, // no gateway
        1, // lo interface index
    ) catch |err| {
        if (err == error.PermissionDenied) return;
        return err;
    };
    defer route.deleteRoute(2, &dst, 24) catch {};
}

// === Interface Tests ===

test "integration: interface list and physical NIC enumeration" {
    const allocator = std.testing.allocator;

    // List all interfaces
    const interfaces = interface.getInterfaces(allocator) catch |err| {
        if (err == error.PermissionDenied or err == error.SocketCreationFailed) return;
        return err;
    };
    defer allocator.free(interfaces);

    // Should have at least loopback
    try std.testing.expect(interfaces.len > 0);

    var has_lo = false;
    for (interfaces) |iface| {
        if (std.mem.eql(u8, iface.getName(), "lo")) {
            has_lo = true;
            try std.testing.expect(iface.isLoopback());
        }
    }
    try std.testing.expect(has_lo);

    // Physical NICs (may be empty in a VM without passthrough)
    const nics = try interface.getPhysicalInterfaces(allocator);
    defer allocator.free(nics);
    // Just verify it doesn't crash - count depends on hardware
}
