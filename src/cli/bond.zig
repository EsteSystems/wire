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

pub fn handleBond(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_w.interface;
        defer stdout.flush() catch {};
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    if (filtered_args.len == 0) {
        // wire bond [--json] - list all bonds
        const bonds = netlink_bond.getBonds(allocator) catch |err| {
            try stdout.print("Failed to get bonds: {}\n", .{err});
            return;
        };
        defer allocator.free(bonds);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator, stdout);
            try json.writeBonds(bonds);
            return;
        }

        if (bonds.len == 0) {
            try stdout.print("No bonds found.\n", .{});
            return;
        }

        // Get interfaces to resolve member names
        const interfaces = netlink_interface.getInterfaces(allocator) catch |err| {
            try stdout.print("Failed to get interfaces: {}\n", .{err});
            return;
        };
        defer allocator.free(interfaces);

        try stdout.print("Bond interfaces:\n", .{});
        try stdout.print("{s:<12} {s:<15} {s}\n", .{ "Name", "Mode", "Members" });
        try stdout.print("{s:-<12} {s:-<15} {s:-<20}\n", .{ "", "", "" });

        for (bonds) |bond| {
            var members_buf: [256]u8 = undefined;
            var members_len: usize = 0;
            for (bond.members, 0..) |member_idx, i| {
                if (i > 0) {
                    members_buf[members_len] = ',';
                    members_buf[members_len + 1] = ' ';
                    members_len += 2;
                }
                // Find interface name by index
                var name: []const u8 = "?";
                for (interfaces) |iface| {
                    if (iface.index == member_idx) {
                        name = iface.getName();
                        break;
                    }
                }
                if (members_len + name.len < members_buf.len) {
                    @memcpy(members_buf[members_len .. members_len + name.len], name);
                    members_len += name.len;
                }
            }
            const members_str = if (members_len > 0) members_buf[0..members_len] else "-";
            try stdout.print("{s:<12} {s:<15} {s}\n", .{ bond.getName(), bond.mode.toString(), members_str });
        }
        return;
    }

    const bond_name = filtered_args[0];

    if (filtered_args.len == 1) {
        // wire bond <name> - show bond details
        try showBondDetails(allocator, bond_name, stdout);
        return;
    }

    const action = filtered_args[1];

    // wire bond <name> create mode <mode> [options]
    if (std.mem.eql(u8, action, "create")) {
        var options = netlink_bond.BondOptions{};

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "mode") and i + 1 < filtered_args.len) {
                options.mode = netlink_bond.BondMode.fromString(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid bond mode: {s}\n", .{filtered_args[i + 1]});
                    try stdout.print("Valid modes: balance-rr, active-backup, balance-xor, broadcast, 802.3ad, balance-tlb, balance-alb\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "lacp_rate") and i + 1 < filtered_args.len) {
                options.lacp_rate = netlink_bond.LacpRate.fromString(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid LACP rate: {s}\n", .{filtered_args[i + 1]});
                    try stdout.print("Valid rates: slow, fast\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "xmit_hash") and i + 1 < filtered_args.len) {
                options.xmit_hash_policy = netlink_bond.XmitHashPolicy.fromString(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid xmit_hash policy: {s}\n", .{filtered_args[i + 1]});
                    try stdout.print("Valid policies: layer2, layer3+4, layer2+3, encap2+3, encap3+4, vlan+srcmac\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "ad_select") and i + 1 < filtered_args.len) {
                options.ad_select = netlink_bond.AdSelect.fromString(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid ad_select: {s}\n", .{filtered_args[i + 1]});
                    try stdout.print("Valid options: stable, bandwidth, count\n", .{});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "miimon") and i + 1 < filtered_args.len) {
                options.miimon = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid miimon value: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        netlink_bond.createBondWithOptions(bond_name, options) catch |err| {
            try stdout.print("Failed to create bond: {}\n", .{err});
            return;
        };

        // Build status message
        try stdout.print("Bond {s} created with mode {s}", .{ bond_name, options.mode.toString() });
        if (options.lacp_rate) |rate| {
            try stdout.print(", lacp_rate={s}", .{rate.toString()});
        }
        if (options.xmit_hash_policy) |policy| {
            try stdout.print(", xmit_hash={s}", .{policy.toString()});
        }
        if (options.ad_select) |sel| {
            try stdout.print(", ad_select={s}", .{sel.toString()});
        }
        try stdout.print("\n", .{});
        return;
    }

    // wire bond <name> delete
    if (std.mem.eql(u8, action, "delete")) {
        netlink_bond.deleteBond(bond_name) catch |err| {
            try stdout.print("Failed to delete bond: {}\n", .{err});
            return;
        };
        try stdout.print("Bond {s} deleted\n", .{bond_name});
        return;
    }

    // wire bond <name> add <member>
    if (std.mem.eql(u8, action, "add") and filtered_args.len >= 3) {
        for (filtered_args[2..]) |member| {
            netlink_bond.addBondMember(bond_name, member) catch |err| {
                try stdout.print("Failed to add {s} to bond: {}\n", .{ member, err });
                continue;
            };
            try stdout.print("Added {s} to {s}\n", .{ member, bond_name });
        }
        return;
    }

    // wire bond <name> del <member>
    if (std.mem.eql(u8, action, "del") and filtered_args.len >= 3) {
        for (filtered_args[2..]) |member| {
            netlink_bond.removeBondMember(member) catch |err| {
                try stdout.print("Failed to remove {s} from bond: {}\n", .{ member, err });
                continue;
            };
            try stdout.print("Removed {s} from bond\n", .{member});
        }
        return;
    }

    // wire bond <name> show
    if (std.mem.eql(u8, action, "show")) {
        try showBondDetails(allocator, bond_name, stdout);
        return;
    }

    try stdout.print("Unknown bond action: {s}\n", .{action});
}

fn showBondDetails(allocator: std.mem.Allocator, name: []const u8, stdout: anytype) !void {
    // Get the interface info
    const maybe_iface = try netlink_interface.getInterfaceByName(allocator, name);
    if (maybe_iface == null) {
        try stdout.print("Bond {s} not found\n", .{name});
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
