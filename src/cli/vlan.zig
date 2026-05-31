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

pub fn handleVlan(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    if (args.len == 0) {
        try stdout.print("VLAN commands:\n", .{});
        try stdout.print("  vlan <id> on <parent>           Create VLAN (<parent>.<id>)\n", .{});
        try stdout.print("  vlan <id> on <parent> name <n>  Create VLAN with custom name\n", .{});
        try stdout.print("  vlan <name> delete              Delete VLAN interface\n", .{});
        try stdout.print("  vlan <name> show                Show VLAN details\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire vlan 100 on eth0           Creates eth0.100\n", .{});
        try stdout.print("  wire vlan 100 on eth0 name mgmt Creates 'mgmt' VLAN\n", .{});
        return;
    }

    // Parse VLAN ID
    const first_arg = args[0];

    // Check if first arg is a VLAN ID (number)
    const vlan_id = std.fmt.parseInt(u16, first_arg, 10) catch {
        // Not a number - treat as interface name for show/delete
        const iface_name = first_arg;

        if (args.len >= 2 and std.mem.eql(u8, args[1], "delete")) {
            netlink_vlan.deleteVlan(iface_name) catch |err| {
                try stdout.print("Failed to delete VLAN: {}\n", .{err});
                return;
            };
            try stdout.print("VLAN {s} deleted\n", .{iface_name});
            return;
        }

        if (args.len == 1 or std.mem.eql(u8, args[1], "show")) {
            try showVlanDetails(allocator, iface_name, stdout);
            return;
        }

        try stdout.print("Unknown VLAN action. Run 'wire vlan' for help.\n", .{});
        return;
    };

    // Validate VLAN ID
    if (vlan_id < 1 or vlan_id > 4094) {
        try stdout.print("Invalid VLAN ID: {d} (must be 1-4094)\n", .{vlan_id});
        return;
    }

    // wire vlan <id> on <parent> [name <name>]
    if (args.len >= 3 and std.mem.eql(u8, args[1], "on")) {
        const parent_name = args[2];
        var custom_name: ?[]const u8 = null;

        // Check for optional 'name' parameter
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "name") and i + 1 < args.len) {
                custom_name = args[i + 1];
                i += 1;
            }
        }

        if (custom_name) |name| {
            netlink_vlan.createVlanWithName(parent_name, vlan_id, name) catch |err| {
                try stdout.print("Failed to create VLAN: {}\n", .{err});
                return;
            };
            try stdout.print("VLAN {s} created (ID {d} on {s})\n", .{ name, vlan_id, parent_name });
        } else {
            netlink_vlan.createVlan(parent_name, vlan_id) catch |err| {
                try stdout.print("Failed to create VLAN: {}\n", .{err});
                return;
            };
            try stdout.print("VLAN {s}.{d} created\n", .{ parent_name, vlan_id });
        }
        return;
    }

    try stdout.print("Invalid VLAN command. Run 'wire vlan' for help.\n", .{});
}

fn showVlanDetails(allocator: std.mem.Allocator, name: []const u8, stdout: anytype) !void {
    // Get the interface info
    const maybe_iface = try netlink_interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        try stdout.print("VLAN {s} not found\n", .{name});
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
