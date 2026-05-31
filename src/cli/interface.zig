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

pub fn handleInterface(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    // wire interface (list all)
    if (filtered_args.len == 0) {
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator, stdout);
            // Collect addresses for each interface
            var addr_lists = try allocator.alloc([]const netlink_address.Address, interfaces.len);
            defer {
                for (addr_lists) |addrs| allocator.free(addrs);
                allocator.free(addr_lists);
            }
            for (interfaces, 0..) |iface, i| {
                addr_lists[i] = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
            }
            try json.writeInterfaces(interfaces, addr_lists);
            return;
        }

        for (interfaces) |iface| {
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

            // Get addresses for this interface
            const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
            defer allocator.free(addrs);

            for (addrs) |addr| {
                var addr_buf: [64]u8 = undefined;
                const addr_str = try addr.formatAddress(&addr_buf);
                const family = if (addr.isIPv4()) "inet" else "inet6";
                try stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() });
            }
        }
        return;
    }

    const iface_name = filtered_args[0];

    // wire interface <name> show
    if (filtered_args.len == 1 or std.mem.eql(u8, filtered_args[1], "show")) {
        const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);

        if (maybe_iface) |iface| {
            // Get addresses
            const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
            defer allocator.free(addrs);

            if (use_json) {
                var json = json_output.JsonOutput.init(allocator, stdout);
                try json.writeInterface(&iface, addrs);
                try stdout.writeAll("\n");
                return;
            }

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

            try stdout.print("    operstate: {s}\n", .{iface.operstateString()});

            for (addrs) |addr| {
                var addr_buf: [64]u8 = undefined;
                const addr_str = try addr.formatAddress(&addr_buf);
                const family = if (addr.isIPv4()) "inet" else "inet6";
                try stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() });
            }
        } else {
            if (use_json) {
                var json = json_output.JsonOutput.init(allocator, stdout);
                try json.writeError("Interface not found");
                return;
            }
            try stdout.print("Interface {s} not found\n", .{iface_name});
        }
        return;
    }

    const action = filtered_args[1];

    // wire interface <name> set state up|down
    if (std.mem.eql(u8, action, "set") and filtered_args.len >= 4) {
        const attr = filtered_args[2];

        if (std.mem.eql(u8, attr, "state")) {
            const state_val = filtered_args[3];
            if (std.mem.eql(u8, state_val, "up")) {
                try netlink_interface.setInterfaceState(iface_name, true);
                try stdout.print("Interface {s} set to UP\n", .{iface_name});
            } else if (std.mem.eql(u8, state_val, "down")) {
                try netlink_interface.setInterfaceState(iface_name, false);
                try stdout.print("Interface {s} set to DOWN\n", .{iface_name});
            } else {
                try stdout.print("Invalid state: {s} (use 'up' or 'down')\n", .{state_val});
            }
        } else if (std.mem.eql(u8, attr, "mtu")) {
            const mtu_val = std.fmt.parseInt(u32, filtered_args[3], 10) catch {
                try stdout.print("Invalid MTU value: {s}\n", .{filtered_args[3]});
                return;
            };
            try netlink_interface.setInterfaceMtu(iface_name, mtu_val);
            try stdout.print("Interface {s} MTU set to {d}\n", .{ iface_name, mtu_val });
        } else {
            try stdout.print("Unknown attribute: {s}\n", .{attr});
        }
        return;
    }

    // wire interface <name> stats
    if (std.mem.eql(u8, action, "stats")) {
        try handleInterfaceStats(allocator, io, iface_name);
        return;
    }

    // wire interface <name> address <ip/prefix>
    if (std.mem.eql(u8, action, "address") and filtered_args.len >= 3) {
        const addr_str = filtered_args[2];

        // Get interface index
        const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);
        if (maybe_iface == null) {
            try stdout.print("Interface {s} not found\n", .{iface_name});
            return;
        }
        const iface = maybe_iface.?;

        // Check if this is a delete operation
        if (std.mem.eql(u8, addr_str, "del") and filtered_args.len >= 4) {
            const del_addr = filtered_args[3];
            const parsed = netlink_address.parseIPv4(del_addr) catch {
                try stdout.print("Invalid address: {s}\n", .{del_addr});
                return;
            };
            try netlink_address.deleteAddress(@intCast(iface.index), linux.AF.INET, &parsed.addr, parsed.prefix);
            try stdout.print("Deleted {s} from {s}\n", .{ del_addr, iface_name });
            return;
        }

        // Add address
        const parsed = netlink_address.parseIPv4(addr_str) catch {
            try stdout.print("Invalid address: {s}\n", .{addr_str});
            return;
        };

        try netlink_address.addAddress(@intCast(iface.index), linux.AF.INET, &parsed.addr, parsed.prefix);
        try stdout.print("Added {s} to {s}\n", .{ addr_str, iface_name });
        return;
    }

    try stdout.print("Unknown action: {s}\n", .{action});
}

pub fn handleInterfaceStats(allocator: std.mem.Allocator, io: std.Io, iface_name: []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};

    const iface_stats = stats.getInterfaceStatsByName(allocator, iface_name) catch |err| {
        try stdout.print("Failed to get statistics: {}\n", .{err});
        return;
    };

    if (iface_stats) |*s| {
        try stdout.print("{s} statistics:\n", .{iface_name});
        try s.format(stdout);
    } else {
        try stdout.print("No statistics found for {s}\n", .{iface_name});
    }
}

