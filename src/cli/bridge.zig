const std = @import("std");
const compat = @import("../compat.zig");
const netlink_interface = @import("../netlink/interface.zig");
const netlink_address = @import("../netlink/address.zig");
const netlink_route = @import("../netlink/route.zig");
const netlink_bond = @import("../netlink/bond.zig");
const netlink_bridge = @import("../netlink/bridge.zig");
const netlink_vlan = @import("../netlink/vlan.zig");
const netlink_veth = @import("../netlink/veth.zig");
const config_loader = @import("../config/loader.zig");
const state_types = @import("../state/types.zig");
const state_live = @import("../state/live.zig");
const state_desired = @import("../state/desired.zig");
const state_diff = @import("../state/diff.zig");
const state_exporter = @import("../state/exporter.zig");
const netlink_events = @import("../netlink/events.zig");
const reconciler = @import("../daemon/reconciler.zig");
const supervisor = @import("../daemon/supervisor.zig");
const ipc = @import("../daemon/ipc.zig");
const connectivity = @import("../analysis/connectivity.zig");
const health = @import("../analysis/health.zig");
const snapshots = @import("../history/snapshots.zig");
const changelog = @import("../history/changelog.zig");
const neighbor = @import("../netlink/neighbor.zig");
const ip_rule = @import("../netlink/rule.zig");
const namespace = @import("../netlink/namespace.zig");
const ethtool = @import("../netlink/ethtool.zig");
const tunnel = @import("../netlink/tunnel.zig");
const qdisc = @import("../netlink/qdisc.zig");
const stats = @import("../netlink/stats.zig");
const topology = @import("../analysis/topology.zig");
const native_ping = @import("../plugins/native/ping.zig");
const native_trace = @import("../plugins/native/traceroute.zig");
const native_capture = @import("../plugins/native/capture.zig");
const path_trace = @import("../diagnostics/trace.zig");
const probe = @import("../diagnostics/probe.zig");
const validate = @import("../diagnostics/validate.zig");
const watch = @import("../diagnostics/watch.zig");
const json_output = @import("../output/json.zig");
const linux = std.os.linux;

const version = "1.0.0";

pub fn handleBridge(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("Bridge commands:\n", .{});
        try stdout.print("  bridge <name> create           Create bridge\n", .{});
        try stdout.print("  bridge <name> add <port>       Add port to bridge\n", .{});
        try stdout.print("  bridge <name> del <port>       Remove port from bridge\n", .{});
        try stdout.print("  bridge <name> delete           Delete bridge\n", .{});
        try stdout.print("  bridge <name> show             Show bridge details\n", .{});
        try stdout.print("  bridge <name> stp on|off       Enable/disable STP\n", .{});
        try stdout.print("  bridge <name> fdb              Show FDB (forwarding database)\n", .{});
        try stdout.print("  bridge fdb                     Show all FDB entries\n", .{});
        return;
    }

    const bridge_name = args[0];

    // wire bridge fdb - show all FDB entries
    if (std.mem.eql(u8, bridge_name, "fdb")) {
        try showAllBridgeFdb(allocator, stdout);
        return;
    }

    if (args.len == 1) {
        // wire bridge <name> - show bridge details
        try showBridgeDetails(allocator, bridge_name, stdout);
        return;
    }

    const action = args[1];

    // wire bridge <name> create
    if (std.mem.eql(u8, action, "create")) {
        netlink_bridge.createBridge(bridge_name) catch |err| {
            try stdout.print("Failed to create bridge: {}\n", .{err});
            return;
        };
        try stdout.print("Bridge {s} created\n", .{bridge_name});
        return;
    }

    // wire bridge <name> delete
    if (std.mem.eql(u8, action, "delete")) {
        netlink_bridge.deleteBridge(bridge_name) catch |err| {
            try stdout.print("Failed to delete bridge: {}\n", .{err});
            return;
        };
        try stdout.print("Bridge {s} deleted\n", .{bridge_name});
        return;
    }

    // wire bridge <name> add <port>
    if (std.mem.eql(u8, action, "add") and args.len >= 3) {
        for (args[2..]) |port| {
            netlink_bridge.addBridgeMember(bridge_name, port) catch |err| {
                try stdout.print("Failed to add {s} to bridge: {}\n", .{ port, err });
                continue;
            };
            try stdout.print("Added {s} to {s}\n", .{ port, bridge_name });
        }
        return;
    }

    // wire bridge <name> del <port>
    if (std.mem.eql(u8, action, "del") and args.len >= 3) {
        for (args[2..]) |port| {
            netlink_bridge.removeBridgeMember(port) catch |err| {
                try stdout.print("Failed to remove {s} from bridge: {}\n", .{ port, err });
                continue;
            };
            try stdout.print("Removed {s} from bridge\n", .{port});
        }
        return;
    }

    // wire bridge <name> stp on|off
    if (std.mem.eql(u8, action, "stp") and args.len >= 3) {
        const state = args[2];
        var enabled = false;

        if (std.mem.eql(u8, state, "on") or std.mem.eql(u8, state, "1")) {
            enabled = true;
        } else if (!std.mem.eql(u8, state, "off") and !std.mem.eql(u8, state, "0")) {
            try stdout.print("Invalid STP state: {s} (use 'on' or 'off')\n", .{state});
            return;
        }

        netlink_bridge.setBridgeStp(bridge_name, enabled) catch |err| {
            try stdout.print("Failed to set STP state: {}\n", .{err});
            return;
        };
        try stdout.print("Bridge {s} STP {s}\n", .{ bridge_name, if (enabled) "enabled" else "disabled" });
        return;
    }

    // wire bridge <name> show
    if (std.mem.eql(u8, action, "show")) {
        try showBridgeDetails(allocator, bridge_name, stdout);
        return;
    }

    // wire bridge <name> fdb
    if (std.mem.eql(u8, action, "fdb")) {
        try showBridgeFdb(allocator, bridge_name, stdout);
        return;
    }

    try stdout.print("Unknown bridge action: {s}\n", .{action});
}

fn showAllBridgeFdb(allocator: std.mem.Allocator, stdout: anytype) !void {
    // Get all FDB entries
    const entries = netlink_bridge.getAllFdb(allocator) catch |err| {
        try stdout.print("Failed to get FDB entries: {}\n", .{err});
        return;
    };
    defer allocator.free(entries);

    // Get interfaces for name lookup
    const interfaces = netlink_interface.getInterfaces(allocator) catch |err| {
        try stdout.print("Failed to query interfaces: {}\n", .{err});
        return;
    };
    defer allocator.free(interfaces);

    if (entries.len == 0) {
        try stdout.print("No FDB entries found.\n", .{});
        return;
    }

    try stdout.print("Bridge FDB ({d} entries)\n", .{entries.len});
    try stdout.print("{s:<20} {s:<6} {s:<12} {s:<12}\n", .{ "MAC Address", "VLAN", "State", "Interface" });
    try stdout.print("{s:-<20} {s:-<6} {s:-<12} {s:-<12}\n", .{ "", "", "", "" });

    for (entries) |*entry| {
        const mac_str = entry.formatMac();

        // VLAN
        var vlan_buf: [8]u8 = undefined;
        const vlan_str = if (entry.vlan) |v|
            std.fmt.bufPrint(&vlan_buf, "{d}", .{v}) catch "-"
        else
            "-";

        // Resolve interface name
        var if_name: []const u8 = "?";
        for (interfaces) |iface| {
            if (iface.index == entry.interface_index) {
                if_name = iface.getName();
                break;
            }
        }

        try stdout.print("{s:<20} {s:<6} {s:<12} {s:<12}\n", .{
            mac_str,
            vlan_str,
            entry.stateString(),
            if_name,
        });
    }
}
fn showBridgeDetails(allocator: std.mem.Allocator, name: []const u8, stdout: anytype) !void {
    // Get the interface info
    const maybe_iface = try netlink_interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        try stdout.print("Bridge {s} not found\n", .{name});
        return;
    }
    const iface = maybe_iface.?;

    const state = if (iface.isUp()) "UP" else "DOWN";
    const carrier = if (iface.hasCarrier()) "CARRIER" else "NO-CARRIER";

    try stdout.print("{d}: {s}: <{s},{s}> mtu {d}\n", .{
        iface.index,
        iface.getName(),
        state,
        carrier,
        iface.mtu,
    });

    if (iface.has_mac) {
        const mac = iface.formatMac();
        try stdout.print("    link/ether {s}\n", .{mac});
    }

    // Get addresses
    const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
    defer allocator.free(addrs);

    for (addrs) |addr| {
        var addr_buf: [64]u8 = undefined;
        const addr_str = try addr.formatAddress(&addr_buf);
        const family = if (addr.isIPv4()) "inet" else "inet6";
        try stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() });
    }
}
fn showBridgeFdb(allocator: std.mem.Allocator, bridge_name: []const u8, stdout: anytype) !void {
    // Get FDB entries for the bridge
    const entries = netlink_bridge.getBridgeFdb(allocator, bridge_name) catch |err| {
        try stdout.print("Failed to get FDB entries: {}\n", .{err});
        return;
    };
    defer allocator.free(entries);

    // Get interfaces for name lookup
    const interfaces = netlink_interface.getInterfaces(allocator) catch |err| {
        try stdout.print("Failed to query interfaces: {}\n", .{err});
        return;
    };
    defer allocator.free(interfaces);

    if (entries.len == 0) {
        try stdout.print("No FDB entries for {s}\n", .{bridge_name});
        return;
    }

    try stdout.print("FDB for {s} ({d} entries)\n", .{ bridge_name, entries.len });
    try stdout.print("{s:<20} {s:<6} {s:<12} {s:<12}\n", .{ "MAC Address", "VLAN", "State", "Port" });
    try stdout.print("{s:-<20} {s:-<6} {s:-<12} {s:-<12}\n", .{ "", "", "", "" });

    for (entries) |*entry| {
        const mac_str = entry.formatMac();

        // VLAN
        var vlan_buf: [8]u8 = undefined;
        const vlan_str = if (entry.vlan) |v|
            std.fmt.bufPrint(&vlan_buf, "{d}", .{v}) catch "-"
        else
            "-";

        // Resolve interface name
        var if_name: []const u8 = "?";
        for (interfaces) |iface| {
            if (iface.index == entry.interface_index) {
                if_name = iface.getName();
                break;
            }
        }

        try stdout.print("{s:<20} {s:<6} {s:<12} {s:<12}\n", .{
            mac_str,
            vlan_str,
            entry.stateString(),
            if_name,
        });
    }
}
