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

pub fn handleNeighbor(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    // Default to show
    var subcommand: []const u8 = "show";
    if (filtered_args.len > 0) {
        subcommand = filtered_args[0];
    }

    if (std.mem.eql(u8, subcommand, "show") or std.mem.eql(u8, subcommand, "list")) {
        // wire neighbor show [interface]
        const neighbors = neighbor.getNeighbors(allocator) catch |err| {
            try stdout.print("Failed to query neighbor table: {}\n", .{err});
            return;
        };
        defer allocator.free(neighbors);

        // Get interfaces for name lookup
        const interfaces = netlink_interface.getInterfaces(allocator) catch |err| {
            try stdout.print("Failed to query interfaces: {}\n", .{err});
            return;
        };
        defer allocator.free(interfaces);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator, stdout);
            try json.writeNeighbors(neighbors, interfaces);
            return;
        }

        // Filter by interface name if provided
        var filter_name: ?[]const u8 = null;
        if (filtered_args.len > 1) {
            filter_name = filtered_args[1];
        }

        var filter_index: ?i32 = null;
        if (filter_name) |name| {
            for (interfaces) |iface| {
                if (std.mem.eql(u8, iface.getName(), name)) {
                    filter_index = iface.index;
                    break;
                }
            }
        }

        if (neighbors.len == 0) {
            try stdout.print("No neighbor entries found.\n", .{});
            return;
        }

        try stdout.print("Neighbor Table\n", .{});
        try stdout.print("{s:<18} {s:<20} {s:<12} {s:<10}\n", .{ "IP Address", "MAC Address", "State", "Interface" });
        try stdout.print("{s:-<18} {s:-<20} {s:-<12} {s:-<10}\n", .{ "", "", "", "" });

        var count: usize = 0;
        for (neighbors) |*entry| {
            // Filter by interface if specified
            if (filter_index) |idx| {
                if (entry.interface_index != idx) continue;
            }

            var ip_buf: [64]u8 = undefined;
            const ip_str = entry.formatAddress(&ip_buf) catch "?";
            const mac_str = entry.formatLladdr();

            // Find interface name
            var if_name: []const u8 = "?";
            for (interfaces) |iface| {
                if (iface.index == entry.interface_index) {
                    if_name = iface.getName();
                    break;
                }
            }

            try stdout.print("{s:<18} {s:<20} {s:<12} {s:<10}\n", .{
                ip_str,
                mac_str,
                entry.state.toString(),
                if_name,
            });
            count += 1;
        }

        try stdout.print("\n{d} entries\n", .{count});
    } else if (std.mem.eql(u8, subcommand, "lookup")) {
        // wire neighbor lookup <ip>
        if (args.len < 2) {
            try stdout.print("Usage: wire neighbor lookup <ip-address>\n", .{});
            return;
        }

        const ip = args[1];
        const entry = neighbor.getNeighborByIP(allocator, ip) catch |err| {
            try stdout.print("Failed to lookup neighbor: {}\n", .{err});
            return;
        };

        if (entry) |*e| {
            var ip_buf: [64]u8 = undefined;
            const ip_str = e.formatAddress(&ip_buf) catch "?";
            const mac_str = e.formatLladdr();

            try stdout.print("{s} -> {s} ({s})\n", .{ ip_str, mac_str, e.state.toString() });
        } else {
            try stdout.print("No neighbor entry found for {s}\n", .{ip});
        }
    } else if (std.mem.eql(u8, subcommand, "arp")) {
        // wire neighbor arp - IPv4 only
        const arp = neighbor.getArpTable(allocator) catch |err| {
            try stdout.print("Failed to query ARP table: {}\n", .{err});
            return;
        };
        defer allocator.free(arp);

        try stdout.print("ARP Table ({d} entries)\n", .{arp.len});
        for (arp) |*entry| {
            var ip_buf: [64]u8 = undefined;
            const ip_str = entry.formatAddress(&ip_buf) catch "?";
            const mac_str = entry.formatLladdr();
            try stdout.print("{s} -> {s} ({s})\n", .{ ip_str, mac_str, entry.state.toString() });
        }
    } else if (std.mem.eql(u8, subcommand, "add")) {
        // wire neighbor add <ip> lladdr <mac> dev <interface> [permanent]
        if (args.len < 6) {
            try stdout.print("Usage: wire neighbor add <ip> lladdr <mac> dev <interface> [permanent]\n", .{});
            try stdout.print("Example: wire neighbor add 10.0.0.50 lladdr aa:bb:cc:dd:ee:ff dev eth0\n", .{});
            return;
        }

        const ip = args[1];
        var mac_str: ?[]const u8 = null;
        var dev_name: ?[]const u8 = null;
        var permanent = false;

        // Parse options
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "lladdr") and i + 1 < args.len) {
                mac_str = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "dev") and i + 1 < args.len) {
                dev_name = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "permanent")) {
                permanent = true;
            }
        }

        if (mac_str == null or dev_name == null) {
            try stdout.print("Missing required options. Need: lladdr <mac> dev <interface>\n", .{});
            return;
        }

        // Parse MAC address
        const mac = neighbor.parseMac(mac_str.?) orelse {
            try stdout.print("Invalid MAC address: {s}\n", .{mac_str.?});
            try stdout.print("Expected format: aa:bb:cc:dd:ee:ff\n", .{});
            return;
        };

        // Get interface index
        const maybe_iface = netlink_interface.getInterfaceByName(allocator, dev_name.?) catch |err| {
            try stdout.print("Failed to find interface: {}\n", .{err});
            return;
        };
        if (maybe_iface == null) {
            try stdout.print("Interface not found: {s}\n", .{dev_name.?});
            return;
        }
        const if_index = maybe_iface.?.index;

        neighbor.addNeighbor(if_index, ip, mac, permanent) catch |err| {
            try stdout.print("Failed to add neighbor entry: {}\n", .{err});
            return;
        };

        const state_str = if (permanent) "permanent" else "reachable";
        try stdout.print("Added neighbor: {s} -> {s} on {s} ({s})\n", .{ ip, mac_str.?, dev_name.?, state_str });
    } else if (std.mem.eql(u8, subcommand, "del") or std.mem.eql(u8, subcommand, "delete")) {
        // wire neighbor del <ip> dev <interface>
        if (args.len < 4) {
            try stdout.print("Usage: wire neighbor del <ip> dev <interface>\n", .{});
            try stdout.print("Example: wire neighbor del 10.0.0.50 dev eth0\n", .{});
            return;
        }

        const ip = args[1];
        var dev_name: ?[]const u8 = null;

        // Parse options
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "dev") and i + 1 < args.len) {
                dev_name = args[i + 1];
                i += 1;
            }
        }

        if (dev_name == null) {
            try stdout.print("Missing required option: dev <interface>\n", .{});
            return;
        }

        // Get interface index
        const maybe_iface = netlink_interface.getInterfaceByName(allocator, dev_name.?) catch |err| {
            try stdout.print("Failed to find interface: {}\n", .{err});
            return;
        };
        if (maybe_iface == null) {
            try stdout.print("Interface not found: {s}\n", .{dev_name.?});
            return;
        }
        const if_index = maybe_iface.?.index;

        neighbor.deleteNeighbor(if_index, ip) catch |err| {
            try stdout.print("Failed to delete neighbor entry: {}\n", .{err});
            return;
        };

        try stdout.print("Deleted neighbor: {s} on {s}\n", .{ ip, dev_name.? });
    } else if (std.mem.eql(u8, subcommand, "help")) {
        try stdout.print("Neighbor commands:\n", .{});
        try stdout.print("  neighbor                                  Show all neighbor entries\n", .{});
        try stdout.print("  neighbor show [interface]                 Show entries (optionally filter by interface)\n", .{});
        try stdout.print("  neighbor lookup <ip>                      Look up specific IP\n", .{});
        try stdout.print("  neighbor arp                              Show ARP table (IPv4 only)\n", .{});
        try stdout.print("  neighbor add <ip> lladdr <mac> dev <if>   Add static entry\n", .{});
        try stdout.print("  neighbor del <ip> dev <if>                Delete entry\n", .{});
        try stdout.print("\nOptions for add:\n", .{});
        try stdout.print("  permanent    Make entry permanent (won't expire)\n", .{});
    } else {
        try stdout.print("Unknown neighbor subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, lookup, arp, add, del, help\n", .{});
    }
}

