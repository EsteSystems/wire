const std = @import("std");
const netlink_interface = @import("netlink/interface.zig");
const netlink_address = @import("netlink/address.zig");
const netlink_route = @import("netlink/route.zig");
const netlink_bond = @import("netlink/bond.zig");
const netlink_bridge = @import("netlink/bridge.zig");
const netlink_vlan = @import("netlink/vlan.zig");
const netlink_veth = @import("netlink/veth.zig");
const config_loader = @import("config/loader.zig");
const state_types = @import("state/types.zig");
const state_live = @import("state/live.zig");
const state_desired = @import("state/desired.zig");
const state_diff = @import("state/diff.zig");
const state_exporter = @import("state/exporter.zig");
const netlink_events = @import("netlink/events.zig");
const reconciler = @import("daemon/reconciler.zig");
const supervisor = @import("daemon/supervisor.zig");
const ipc = @import("daemon/ipc.zig");
const connectivity = @import("analysis/connectivity.zig");
const health = @import("analysis/health.zig");
const snapshots = @import("history/snapshots.zig");
const changelog = @import("history/changelog.zig");
const neighbor = @import("netlink/neighbor.zig");
const stats = @import("netlink/stats.zig");
const topology = @import("analysis/topology.zig");
const native_ping = @import("plugins/native/ping.zig");
const native_trace = @import("plugins/native/traceroute.zig");
const native_capture = @import("plugins/native/capture.zig");
const path_trace = @import("diagnostics/trace.zig");
const probe = @import("diagnostics/probe.zig");
const validate = @import("diagnostics/validate.zig");
const watch = @import("diagnostics/watch.zig");
const linux = std.os.linux;

const version = "0.5.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try printVersion();
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
        return;
    }

    // Execute command
    executeCommand(allocator, args[1..]) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn executeCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printUsage();
        return;
    }

    const subject = args[0];

    if (std.mem.eql(u8, subject, "interface")) {
        try handleInterface(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "route")) {
        try handleRoute(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "analyze")) {
        try handleAnalyze(allocator);
    } else if (std.mem.eql(u8, subject, "apply")) {
        try handleApply(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "validate")) {
        try handleValidate(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "bond")) {
        try handleBond(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "bridge")) {
        try handleBridge(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "vlan")) {
        try handleVlan(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "veth")) {
        try handleVeth(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "state")) {
        try handleState(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "diff")) {
        try handleDiff(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "events")) {
        try handleEvents(args[1..]);
    } else if (std.mem.eql(u8, subject, "reconcile")) {
        try handleReconcile(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "daemon")) {
        try handleDaemon(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "history")) {
        try handleHistory(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "neighbor")) {
        try handleNeighbor(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "topology")) {
        try handleTopology(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "diagnose")) {
        try handleDiagnose(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "trace")) {
        try handlePathTrace(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "probe")) {
        try handleProbe(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "validate")) {
        try handleValidate(allocator, args[1..]);
    } else if (std.mem.eql(u8, subject, "watch")) {
        try handleWatch(allocator, args[1..]);
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Unknown command: {s}\n", .{subject});
        try stderr.print("Run 'wire --help' for usage.\n", .{});
    }
}

fn handleInterface(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // wire interface (list all)
    if (args.len == 0) {
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

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

    const iface_name = args[0];

    // wire interface <name> show
    if (args.len == 1 or std.mem.eql(u8, args[1], "show")) {
        const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);

        if (maybe_iface) |iface| {
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

            // Get addresses
            const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
            defer allocator.free(addrs);

            for (addrs) |addr| {
                var addr_buf: [64]u8 = undefined;
                const addr_str = try addr.formatAddress(&addr_buf);
                const family = if (addr.isIPv4()) "inet" else "inet6";
                try stdout.print("    {s} {s} scope {s}\n", .{ family, addr_str, addr.scopeString() });
            }
        } else {
            try stdout.print("Interface {s} not found\n", .{iface_name});
        }
        return;
    }

    const action = args[1];

    // wire interface <name> set state up|down
    if (std.mem.eql(u8, action, "set") and args.len >= 4) {
        const attr = args[2];

        if (std.mem.eql(u8, attr, "state")) {
            const state_val = args[3];
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
            const mtu_val = std.fmt.parseInt(u32, args[3], 10) catch {
                try stdout.print("Invalid MTU value: {s}\n", .{args[3]});
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
        try handleInterfaceStats(allocator, iface_name);
        return;
    }

    // wire interface <name> address <ip/prefix>
    if (std.mem.eql(u8, action, "address") and args.len >= 3) {
        const addr_str = args[2];

        // Get interface index
        const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);
        if (maybe_iface == null) {
            try stdout.print("Interface {s} not found\n", .{iface_name});
            return;
        }
        const iface = maybe_iface.?;

        // Check if this is a delete operation
        if (std.mem.eql(u8, addr_str, "del") and args.len >= 4) {
            const del_addr = args[3];
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

fn handleRoute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // wire route show (or just 'wire route')
    if (args.len == 0 or std.mem.eql(u8, args[0], "show")) {
        const routes = try netlink_route.getRoutes(allocator);
        defer allocator.free(routes);

        // Get interfaces for name lookup
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        for (routes) |route| {
            // Skip local/broadcast routes
            if (route.route_type != 1) continue; // Only unicast

            var dst_buf: [64]u8 = undefined;
            const dst = try route.formatDst(&dst_buf);

            try stdout.print("{s}", .{dst});

            if (route.has_gateway) {
                var gw_buf: [64]u8 = undefined;
                const gw = try route.formatGateway(&gw_buf);
                try stdout.print(" via {s}", .{gw});
            }

            // Find interface name
            if (route.oif != 0) {
                for (interfaces) |iface| {
                    if (@as(u32, @intCast(iface.index)) == route.oif) {
                        try stdout.print(" dev {s}", .{iface.getName()});
                        break;
                    }
                }
            }

            try stdout.print(" proto {s}", .{route.protocolString()});

            if (route.priority != 0) {
                try stdout.print(" metric {d}", .{route.priority});
            }

            try stdout.print("\n", .{});
        }
        return;
    }

    const action = args[0];

    // wire route add <dst> via <gateway>
    // wire route add <dst> dev <interface>
    // wire route add default via <gateway>
    if (std.mem.eql(u8, action, "add") and args.len >= 2) {
        const dst_str = args[1];
        var gateway: ?[4]u8 = null;
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;
        var oif: ?u32 = null;

        // Parse destination
        if (std.mem.eql(u8, dst_str, "default")) {
            dst_len = 0; // default route
        } else {
            const parsed = netlink_address.parseIPv4(dst_str) catch {
                try stdout.print("Invalid destination: {s}\n", .{dst_str});
                return;
            };
            dst = parsed.addr;
            dst_len = parsed.prefix;
        }

        // Look for 'via' and 'dev'
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "via") and i + 1 < args.len) {
                const gw_parsed = netlink_address.parseIPv4(args[i + 1]) catch {
                    try stdout.print("Invalid gateway: {s}\n", .{args[i + 1]});
                    return;
                };
                gateway = gw_parsed.addr;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "dev") and i + 1 < args.len) {
                const iface_name = args[i + 1];
                const maybe_iface = try netlink_interface.getInterfaceByName(allocator, iface_name);
                if (maybe_iface == null) {
                    try stdout.print("Interface {s} not found\n", .{iface_name});
                    return;
                }
                oif = @intCast(maybe_iface.?.index);
                i += 1;
            }
        }

        // Must have either gateway or device
        if (gateway == null and oif == null) {
            try stdout.print("Route requires either 'via <gateway>' or 'dev <interface>'\n", .{});
            return;
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;
        const gw_slice: ?[]const u8 = if (gateway) |*g| g[0..4] else null;

        try netlink_route.addRoute(linux.AF.INET, dst_slice, dst_len, gw_slice, oif);
        try stdout.print("Route added\n", .{});
        return;
    }

    // wire route del <dst>
    if (std.mem.eql(u8, action, "del") and args.len >= 2) {
        const dst_str = args[1];
        var dst: ?[4]u8 = null;
        var dst_len: u8 = 0;

        if (std.mem.eql(u8, dst_str, "default")) {
            dst_len = 0;
        } else {
            const parsed = netlink_address.parseIPv4(dst_str) catch {
                try stdout.print("Invalid destination: {s}\n", .{dst_str});
                return;
            };
            dst = parsed.addr;
            dst_len = parsed.prefix;
        }

        const dst_slice: ?[]const u8 = if (dst) |*d| d[0..4] else null;

        try netlink_route.deleteRoute(linux.AF.INET, dst_slice, dst_len);
        try stdout.print("Route deleted\n", .{});
        return;
    }

    try stdout.print("Unknown action: {s}\n", .{action});
}

fn handleAnalyze(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\nNetwork Analysis Report\n", .{});
    try stdout.print("=======================\n\n", .{});

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch {
        try stdout.print("Error: Could not query network state\n", .{});
        return;
    };
    defer live_state.deinit();

    // Connectivity Analysis
    var conn_analyzer = connectivity.ConnectivityAnalyzer.init(allocator);
    defer conn_analyzer.deinit();

    _ = conn_analyzer.analyze(&live_state) catch {};
    try conn_analyzer.format(stdout);
    try stdout.print("\n", .{});

    // Configuration Health
    var health_analyzer = health.HealthAnalyzer.init(allocator);
    defer health_analyzer.deinit();

    _ = health_analyzer.analyze(&live_state) catch {};
    try health_analyzer.format(stdout);
    try stdout.print("\n", .{});

    // Interface Details
    try stdout.print("Interface Details\n", .{});
    try stdout.print("-----------------\n", .{});

    for (live_state.interfaces.items) |*iface| {
        const status: []const u8 = if (iface.isUp() and iface.hasCarrier())
            "[ok]"
        else if (iface.isUp())
            "[warn]"
        else
            "[down]";

        const addrs = live_state.getAddressesForInterface(iface.index);

        var addr_info: [64]u8 = undefined;
        var addr_len: usize = 0;

        if (addrs.len > 0) {
            if (addrs[0].family == 2) {
                const addr_str = std.fmt.bufPrint(&addr_info, "{d}.{d}.{d}.{d}/{d}", .{
                    addrs[0].address[0],
                    addrs[0].address[1],
                    addrs[0].address[2],
                    addrs[0].address[3],
                    addrs[0].prefix_len,
                }) catch continue;
                addr_len = addr_str.len;
            }
        }

        const state = if (iface.isUp()) "up" else "down";
        const carrier = if (iface.hasCarrier()) "carrier" else "no-carrier";

        if (addr_len > 0) {
            try stdout.print("{s} {s}: {s}, {s}, {s}\n", .{ status, iface.getName(), state, carrier, addr_info[0..addr_len] });
        } else if (iface.link_type != .loopback) {
            try stdout.print("{s} {s}: {s}, {s}, no address\n", .{ status, iface.getName(), state, carrier });
        } else {
            try stdout.print("{s} {s}: {s}, loopback\n", .{ status, iface.getName(), state });
        }
    }

    // Summary
    try stdout.print("\nSummary\n", .{});
    try stdout.print("-------\n", .{});

    const conn_counts = conn_analyzer.countByStatus();
    const health_counts = health_analyzer.countByStatus();
    const overall = health_analyzer.overallStatus();

    try stdout.print("Connectivity: {d} ok, {d} warnings, {d} errors\n", .{ conn_counts.ok, conn_counts.warning, conn_counts.err });
    try stdout.print("Health: {d} healthy, {d} degraded, {d} unhealthy\n", .{ health_counts.healthy, health_counts.degraded, health_counts.unhealthy });
    try stdout.print("Overall status: {s}\n", .{switch (overall) {
        .healthy => "HEALTHY",
        .degraded => "DEGRADED",
        .unhealthy => "UNHEALTHY",
    }});

    try stdout.print("\n", .{});
}

fn handleApply(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Usage: wire apply <config-file> [--dry-run] [--yes]\n", .{});
        try stdout.print("\nOptions:\n", .{});
        try stdout.print("  --dry-run, -n    Validate without applying changes\n", .{});
        try stdout.print("  --yes, -y        Skip confirmation prompt\n", .{});
        return;
    }

    const config_path = args[0];
    var dry_run = false;
    var skip_confirmation = false;

    // Check for flags
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            skip_confirmation = true;
        }
    }

    const options = config_loader.ApplyOptions{
        .dry_run = dry_run,
        .skip_confirmation = skip_confirmation,
    };

    const result = config_loader.applyConfig(config_path, allocator, options) catch |err| {
        try stdout.print("Failed to apply configuration: {}\n", .{err});
        return;
    };

    if (!result.success) {
        std.process.exit(1);
    }
}

fn handleBond(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Bond commands:\n", .{});
        try stdout.print("  bond <name> create mode <mode> Create bond\n", .{});
        try stdout.print("  bond <name> add <member>       Add member to bond\n", .{});
        try stdout.print("  bond <name> del <member>       Remove member from bond\n", .{});
        try stdout.print("  bond <name> delete             Delete bond\n", .{});
        try stdout.print("  bond <name> show               Show bond details\n", .{});
        try stdout.print("\nModes: balance-rr, active-backup, balance-xor, broadcast, 802.3ad, balance-tlb, balance-alb\n", .{});
        return;
    }

    const bond_name = args[0];

    if (args.len == 1) {
        // wire bond <name> - show bond details
        try showBondDetails(allocator, bond_name, stdout);
        return;
    }

    const action = args[1];

    // wire bond <name> create mode <mode>
    if (std.mem.eql(u8, action, "create")) {
        var mode: netlink_bond.BondMode = .balance_rr; // default

        // Look for mode
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "mode") and i + 1 < args.len) {
                mode = netlink_bond.BondMode.fromString(args[i + 1]) orelse {
                    try stdout.print("Invalid bond mode: {s}\n", .{args[i + 1]});
                    try stdout.print("Valid modes: balance-rr, active-backup, balance-xor, broadcast, 802.3ad, balance-tlb, balance-alb\n", .{});
                    return;
                };
                i += 1;
            }
        }

        netlink_bond.createBond(bond_name, mode) catch |err| {
            try stdout.print("Failed to create bond: {}\n", .{err});
            return;
        };
        try stdout.print("Bond {s} created with mode {s}\n", .{ bond_name, mode.toString() });
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
    if (std.mem.eql(u8, action, "add") and args.len >= 3) {
        for (args[2..]) |member| {
            netlink_bond.addBondMember(bond_name, member) catch |err| {
                try stdout.print("Failed to add {s} to bond: {}\n", .{ member, err });
                continue;
            };
            try stdout.print("Added {s} to {s}\n", .{ member, bond_name });
        }
        return;
    }

    // wire bond <name> del <member>
    if (std.mem.eql(u8, action, "del") and args.len >= 3) {
        for (args[2..]) |member| {
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

fn handleBridge(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

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

fn handleVlan(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

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

fn handleVeth(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Veth pair commands:\n", .{});
        try stdout.print("  veth <name> peer <peer>        Create veth pair\n", .{});
        try stdout.print("  veth <name> delete             Delete veth pair\n", .{});
        try stdout.print("  veth <name> show               Show veth details\n", .{});
        try stdout.print("  veth <name> netns <pid>        Move veth to namespace (by PID)\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire veth veth0 peer veth1     Creates veth0 <-> veth1 pair\n", .{});
        try stdout.print("  wire veth veth0 delete         Deletes veth0 (and veth1)\n", .{});
        try stdout.print("  wire veth veth1 netns 12345    Moves veth1 to PID 12345's netns\n", .{});
        return;
    }

    const veth_name = args[0];

    if (args.len == 1) {
        // wire veth <name> - show veth details
        try showVethDetails(allocator, veth_name, stdout);
        return;
    }

    const action = args[1];

    // wire veth <name> peer <peer_name>
    if (std.mem.eql(u8, action, "peer")) {
        if (args.len < 3) {
            try stdout.print("Missing peer name. Usage: wire veth <name> peer <peer_name>\n", .{});
            return;
        }
        const peer_name = args[2];

        netlink_veth.createVethPair(veth_name, peer_name) catch |err| {
            try stdout.print("Failed to create veth pair: {}\n", .{err});
            return;
        };
        try stdout.print("Veth pair created: {s} <-> {s}\n", .{ veth_name, peer_name });
        return;
    }

    // wire veth <name> delete
    if (std.mem.eql(u8, action, "delete")) {
        netlink_veth.deleteVeth(veth_name) catch |err| {
            try stdout.print("Failed to delete veth: {}\n", .{err});
            return;
        };
        try stdout.print("Veth {s} deleted (and its peer)\n", .{veth_name});
        return;
    }

    // wire veth <name> show
    if (std.mem.eql(u8, action, "show")) {
        try showVethDetails(allocator, veth_name, stdout);
        return;
    }

    // wire veth <name> netns <pid>
    if (std.mem.eql(u8, action, "netns")) {
        if (args.len < 3) {
            try stdout.print("Missing PID. Usage: wire veth <name> netns <pid>\n", .{});
            return;
        }
        const pid = std.fmt.parseInt(i32, args[2], 10) catch {
            try stdout.print("Invalid PID: {s}\n", .{args[2]});
            return;
        };

        netlink_veth.setVethNetnsbyPid(veth_name, pid) catch |err| {
            try stdout.print("Failed to move veth to namespace: {}\n", .{err});
            return;
        };
        try stdout.print("Veth {s} moved to namespace of PID {d}\n", .{ veth_name, pid });
        return;
    }

    try stdout.print("Unknown veth action: {s}. Run 'wire veth' for help.\n", .{action});
}

fn showVethDetails(allocator: std.mem.Allocator, name: []const u8, writer: anytype) !void {
    const veth = netlink_veth.getVethInfo(allocator, name) catch |err| {
        try writer.print("Error getting veth info: {}\n", .{err});
        return;
    };

    if (veth == null) {
        try writer.print("Interface {s} not found or is not a veth\n", .{name});
        return;
    }

    const v = veth.?;
    try writer.print("Veth: {s}\n", .{v.getName()});
    try writer.print("  Index: {d}\n", .{v.index});
    try writer.print("  State: {s}\n", .{if (v.isUp()) "UP" else "DOWN"});
    if (v.peer_name_len > 0) {
        try writer.print("  Peer: {s} (index {d})\n", .{ v.getPeerName(), v.peer_index });
    } else if (v.peer_index > 0) {
        try writer.print("  Peer: index {d} (in different namespace)\n", .{v.peer_index});
    } else {
        try writer.print("  Peer: unknown\n", .{});
    }
}

fn handleState(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Handle subcommands
    if (args.len > 0) {
        const subcmd = args[0];
        if (std.mem.eql(u8, subcmd, "export")) {
            try handleStateExport(allocator, args[1..]);
            return;
        } else if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help")) {
            try stdout.print("State commands:\n", .{});
            try stdout.print("  wire state                  Show live network state\n", .{});
            try stdout.print("  wire state export [file]    Export state to wire config format\n", .{});
            try stdout.print("\nExport options:\n", .{});
            try stdout.print("  --interfaces-only           Only export interfaces\n", .{});
            try stdout.print("  --routes-only               Only export routes\n", .{});
            try stdout.print("  --all                       Include all state (loopback, kernel routes)\n", .{});
            try stdout.print("  --no-comments               Omit comments from output\n", .{});
            return;
        }
    }

    try stdout.print("Querying live network state...\n\n", .{});

    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query live state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Print interfaces
    try stdout.print("Interfaces ({d}):\n", .{live_state.interfaces.items.len});
    for (live_state.interfaces.items) |iface| {
        const state_str = if (iface.isUp()) "UP" else "DOWN";
        try stdout.print("  {s}: {s}, mtu {d}, type {s}\n", .{
            iface.getName(),
            state_str,
            iface.mtu,
            @tagName(iface.link_type),
        });
    }

    // Print addresses
    try stdout.print("\nAddresses ({d}):\n", .{live_state.addresses.items.len});
    for (live_state.addresses.items) |addr| {
        const family = if (addr.isIPv4()) "IPv4" else "IPv6";
        if (addr.isIPv4()) {
            try stdout.print("  {s}: {d}.{d}.{d}.{d}/{d}\n", .{
                family,
                addr.address[0],
                addr.address[1],
                addr.address[2],
                addr.address[3],
                addr.prefix_len,
            });
        }
    }

    // Print routes
    try stdout.print("\nRoutes ({d}):\n", .{live_state.routes.items.len});
    for (live_state.routes.items) |route| {
        if (route.isDefault()) {
            try stdout.print("  default via {d}.{d}.{d}.{d}\n", .{
                route.gateway[0],
                route.gateway[1],
                route.gateway[2],
                route.gateway[3],
            });
        } else if (route.family == 2) {
            try stdout.print("  {d}.{d}.{d}.{d}/{d}", .{
                route.dst[0],
                route.dst[1],
                route.dst[2],
                route.dst[3],
                route.dst_len,
            });
            if (route.has_gateway) {
                try stdout.print(" via {d}.{d}.{d}.{d}", .{
                    route.gateway[0],
                    route.gateway[1],
                    route.gateway[2],
                    route.gateway[3],
                });
            }
            try stdout.print("\n", .{});
        }
    }
}

fn handleStateExport(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Parse options
    var options = state_exporter.ExportOptions.default;
    var output_file: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--interfaces-only")) {
            options = state_exporter.ExportOptions.interfaces_only;
        } else if (std.mem.eql(u8, arg, "--routes-only")) {
            options = state_exporter.ExportOptions.routes_only;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.skip_loopback = false;
            options.skip_auto_addresses = false;
            options.skip_kernel_routes = false;
        } else if (std.mem.eql(u8, arg, "--no-comments")) {
            options.comments = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            output_file = arg;
        }
    }

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query live state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Export
    var exporter = state_exporter.StateExporter.init(allocator, options);

    if (output_file) |path| {
        exporter.exportToFile(&live_state, path) catch |err| {
            try stdout.print("Failed to write file: {}\n", .{err});
            return;
        };
        try stdout.print("Exported state to: {s}\n", .{path});
    } else {
        // Export to stdout
        const output = exporter.exportToString(&live_state) catch |err| {
            try stdout.print("Failed to export state: {}\n", .{err});
            return;
        };
        defer allocator.free(output);
        try stdout.print("{s}", .{output});
    }
}

fn handleEvents(args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Parse duration argument (default 10 seconds)
    var duration_secs: i32 = 10;
    if (args.len > 0) {
        duration_secs = std.fmt.parseInt(i32, args[0], 10) catch 10;
    }

    try stdout.print("Monitoring network events for {d} seconds...\n", .{duration_secs});
    try stdout.print("(Make network changes to see events)\n\n", .{});

    // Create event monitor
    var monitor = netlink_events.EventMonitor.initDefault() catch |err| {
        try stdout.print("Failed to create event monitor: {}\n", .{err});
        return;
    };
    defer monitor.deinit();

    // Set up callback context
    const Context = struct {
        stdout: @TypeOf(stdout),
        event_count: u32,

        fn callback(event: netlink_events.NetworkEvent, userdata: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(userdata.?));
            ctx.event_count += 1;

            var buf: [256]u8 = undefined;
            const event_str = netlink_events.formatEvent(&event, &buf) catch "?";
            ctx.stdout.print("[{d}] {s}\n", .{ ctx.event_count, event_str }) catch {};
        }
    };

    var ctx = Context{ .stdout = stdout, .event_count = 0 };
    monitor.setCallback(Context.callback, @ptrCast(&ctx));

    // Poll for events
    const start_time = std.time.timestamp();
    const end_time = start_time + duration_secs;

    while (std.time.timestamp() < end_time) {
        const result = monitor.poll(1000); // 1 second timeout
        if (result < 0) {
            try stdout.print("Error polling events\n", .{});
            break;
        }
    }

    try stdout.print("\nMonitoring complete. {d} events received.\n", .{ctx.event_count});
}

fn handleDaemon(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const pid_file = "/run/wire.pid";
    const socket_path = "/run/wire.sock";

    if (args.len == 0) {
        try stdout.print("Daemon commands:\n", .{});
        try stdout.print("  wire daemon start [config]    Start the daemon\n", .{});
        try stdout.print("  wire daemon stop              Stop the daemon\n", .{});
        try stdout.print("  wire daemon status            Show daemon status (via IPC)\n", .{});
        try stdout.print("  wire daemon reload            Reload configuration (via IPC)\n", .{});
        try stdout.print("  wire daemon diff              Show drift from desired state\n", .{});
        try stdout.print("  wire daemon state             Show live state from daemon\n", .{});
        return;
    }

    const action = args[0];

    if (std.mem.eql(u8, action, "start")) {
        // Check if already running
        if (supervisor.isRunning(pid_file)) {
            try stdout.print("Daemon is already running\n", .{});
            return;
        }

        // Parse start command options
        var config_path: []const u8 = "/etc/wire/network.conf";
        var verbose = false;
        var dry_run = false;

        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
                dry_run = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                config_path = arg;
            }
        }

        try stdout.print("Starting wire daemon with config: {s}\n", .{config_path});

        // Create and start supervisor
        const config = supervisor.DaemonConfig{
            .config_path = config_path,
            .pid_file = pid_file,
            .socket_path = socket_path,
            .verbose = verbose,
            .dry_run = dry_run,
        };

        var sup = supervisor.Supervisor.init(allocator, config);
        defer sup.deinit();

        sup.start() catch |err| {
            try stdout.print("Failed to start daemon: {}\n", .{err});
            return;
        };

    } else if (std.mem.eql(u8, action, "stop")) {
        // Try IPC first, fall back to signal
        if (ipc.isDaemonRunning(socket_path)) {
            var client = ipc.IpcClient.init(allocator, socket_path);
            const response = client.requestStop() catch {
                // Fall back to signal
                try stopViaSignal(stdout, pid_file);
                return;
            };
            defer allocator.free(response);
            try stdout.print("{s}", .{response});
        } else if (supervisor.isRunning(pid_file)) {
            try stopViaSignal(stdout, pid_file);
        } else {
            try stdout.print("Daemon is not running\n", .{});
        }

    } else if (std.mem.eql(u8, action, "status")) {
        // Try IPC first for detailed status
        if (ipc.isDaemonRunning(socket_path)) {
            var client = ipc.IpcClient.init(allocator, socket_path);
            const response = client.getStatus() catch {
                // Fall back to PID check
                try statusViaPid(stdout, pid_file);
                return;
            };
            defer allocator.free(response);
            try stdout.print("Daemon Status (via IPC):\n", .{});
            try stdout.print("{s}", .{response});
        } else {
            try statusViaPid(stdout, pid_file);
        }

    } else if (std.mem.eql(u8, action, "reload")) {
        // Try IPC first
        if (ipc.isDaemonRunning(socket_path)) {
            var client = ipc.IpcClient.init(allocator, socket_path);
            const response = client.requestReload() catch {
                // Fall back to signal
                try reloadViaSignal(stdout, pid_file);
                return;
            };
            defer allocator.free(response);
            try stdout.print("{s}", .{response});
        } else if (supervisor.isRunning(pid_file)) {
            try reloadViaSignal(stdout, pid_file);
        } else {
            try stdout.print("Daemon is not running\n", .{});
        }

    } else if (std.mem.eql(u8, action, "diff")) {
        // Get drift from daemon via IPC
        if (!ipc.isDaemonRunning(socket_path)) {
            try stdout.print("Daemon is not running. Use 'wire diff <config>' for offline comparison.\n", .{});
            return;
        }

        var client = ipc.IpcClient.init(allocator, socket_path);
        const response = client.getDiff() catch |err| {
            try stdout.print("Failed to get diff from daemon: {}\n", .{err});
            return;
        };
        defer allocator.free(response);
        try stdout.print("{s}", .{response});

    } else if (std.mem.eql(u8, action, "state")) {
        // Get live state from daemon via IPC
        if (!ipc.isDaemonRunning(socket_path)) {
            try stdout.print("Daemon is not running. Use 'wire state' for direct query.\n", .{});
            return;
        }

        var client = ipc.IpcClient.init(allocator, socket_path);
        const response = client.getState() catch |err| {
            try stdout.print("Failed to get state from daemon: {}\n", .{err});
            return;
        };
        defer allocator.free(response);
        try stdout.print("{s}", .{response});

    } else {
        try stdout.print("Unknown daemon action: {s}\n", .{action});
        try stdout.print("Run 'wire daemon' for help.\n", .{});
    }
}

fn stopViaSignal(stdout: anytype, pid_file: []const u8) !void {
    try stdout.print("Stopping wire daemon...\n", .{});
    supervisor.sendSignal(pid_file, linux.SIG.TERM) catch |err| {
        try stdout.print("Failed to stop daemon: {}\n", .{err});
        return;
    };
    try stdout.print("Stop signal sent\n", .{});
}

fn statusViaPid(stdout: anytype, pid_file: []const u8) !void {
    const pid = supervisor.readPidFile(pid_file) catch {
        try stdout.print("Daemon is not running\n", .{});
        return;
    };
    try stdout.print("Daemon is running (pid: {d})\n", .{pid});
}

fn reloadViaSignal(stdout: anytype, pid_file: []const u8) !void {
    try stdout.print("Reloading wire daemon configuration...\n", .{});
    supervisor.sendSignal(pid_file, linux.SIG.HUP) catch |err| {
        try stdout.print("Failed to reload daemon: {}\n", .{err});
        return;
    };
    try stdout.print("Reload signal sent\n", .{});
}

fn handleReconcile(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Usage: wire reconcile <config-file> [--dry-run]\n", .{});
        try stdout.print("Apply configuration changes to make live state match config.\n", .{});
        return;
    }

    const config_path = args[0];
    var dry_run = false;

    // Check for --dry-run flag
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        }
    }

    // Load and parse configuration
    var loader = config_loader.ConfigLoader.init(allocator);
    defer loader.deinit();

    var loaded = loader.loadFile(config_path) catch |err| {
        try stdout.print("Failed to load config: {s}\n", .{@errorName(err)});
        return;
    };
    defer loaded.deinit(allocator);

    try stdout.print("Loaded {d} commands from {s}\n", .{ loaded.commands.len, config_path });

    // Build desired state
    var desired_state = state_desired.buildDesiredState(loaded.commands, allocator) catch |err| {
        try stdout.print("Failed to build desired state: {}\n", .{err});
        return;
    };
    defer desired_state.deinit();

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query live state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Compute diff
    var diff = state_diff.compare(&desired_state, &live_state, allocator) catch |err| {
        try stdout.print("Failed to compare states: {}\n", .{err});
        return;
    };
    defer diff.deinit();

    if (diff.isEmpty()) {
        try stdout.print("\nNo changes needed - state is in sync.\n", .{});
        return;
    }

    // Show what we're about to do
    try stdout.print("\nChanges to apply ({d}):\n", .{diff.changes.items.len});
    try state_diff.formatDiff(&diff, stdout);

    if (dry_run) {
        try stdout.print("\nDry run - no changes applied.\n", .{});
        return;
    }

    // Apply changes via reconciler
    try stdout.print("\nApplying changes...\n", .{});

    const policy = reconciler.ReconcilePolicy{
        .dry_run = dry_run,
        .verbose = true,
        .stop_on_error = false,
    };

    var recon = reconciler.Reconciler.init(allocator, policy);
    defer recon.deinit();

    const reconcile_stats = recon.reconcile(&diff) catch |err| {
        try stdout.print("Reconciliation failed: {}\n", .{err});
        return;
    };

    try stdout.print("\nReconciliation complete:\n", .{});
    try stdout.print("  Applied: {d}\n", .{reconcile_stats.applied});
    try stdout.print("  Failed: {d}\n", .{reconcile_stats.failed});

    // Show failures
    if (reconcile_stats.failed > 0) {
        try stdout.print("\nFailed changes:\n", .{});
        for (recon.getResults()) |result| {
            if (!result.success) {
                if (result.error_message) |msg| {
                    try stdout.print("  - {s}: {s}\n", .{ @tagName(result.change), msg });
                }
            }
        }
    }
}

fn handleDiff(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Usage: wire diff <config-file>\n", .{});
        try stdout.print("Compare desired state from config file against live network state.\n", .{});
        return;
    }

    const config_path = args[0];

    // Load and parse configuration
    var loader = config_loader.ConfigLoader.init(allocator);
    defer loader.deinit();

    var loaded = loader.loadFile(config_path) catch |err| {
        try stdout.print("Failed to load config: {s}\n", .{@errorName(err)});
        return;
    };
    defer loaded.deinit(allocator);

    try stdout.print("Loaded {d} commands from {s}\n", .{ loaded.commands.len, config_path });

    // Build desired state
    var desired_state = state_desired.buildDesiredState(loaded.commands, allocator) catch |err| {
        try stdout.print("Failed to build desired state: {}\n", .{err});
        return;
    };
    defer desired_state.deinit();

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query live state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Compare states
    var diff = state_diff.compare(&desired_state, &live_state, allocator) catch |err| {
        try stdout.print("Failed to compare states: {}\n", .{err});
        return;
    };
    defer diff.deinit();

    // Format and print diff
    try stdout.print("\n", .{});
    try state_diff.formatDiff(&diff, stdout);
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

fn handleHistory(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Default to showing recent changes
    var subcommand: []const u8 = "show";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire history show [N]
        var count: usize = 10;
        if (args.len > 1) {
            count = std.fmt.parseInt(usize, args[1], 10) catch 10;
        }

        var logger = changelog.ChangeLogger.init(allocator, null);
        try logger.displayRecent(count, stdout);
    } else if (std.mem.eql(u8, subcommand, "snapshot")) {
        // wire history snapshot - create snapshot now
        var live = state_live.queryLiveState(allocator) catch |err| {
            try stdout.print("Failed to query live state: {}\n", .{err});
            return;
        };
        defer live.deinit();

        var mgr = snapshots.SnapshotManager.init(allocator, null);
        const snap = mgr.createSnapshot(&live) catch |err| {
            try stdout.print("Failed to create snapshot: {}\n", .{err});
            return;
        };

        try stdout.print("Created snapshot: {s}\n", .{snap.getPath()});
        try stdout.print("Timestamp: {d}\n", .{snap.timestamp});
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // wire history list - list all snapshots
        var mgr = snapshots.SnapshotManager.init(allocator, null);
        const snap_list = mgr.listSnapshots() catch |err| {
            try stdout.print("Failed to list snapshots: {}\n", .{err});
            return;
        };
        defer allocator.free(snap_list);

        if (snap_list.len == 0) {
            try stdout.print("No snapshots found.\n", .{});
            return;
        }

        try stdout.print("Snapshots ({d} total)\n", .{snap_list.len});
        try stdout.print("---------------------\n", .{});

        for (snap_list) |*info| {
            try snapshots.SnapshotManager.formatSnapshotInfo(info, stdout);
        }
    } else if (std.mem.eql(u8, subcommand, "diff")) {
        // wire history diff <timestamp> - compare to snapshot
        if (args.len < 2) {
            try stdout.print("Usage: wire history diff <timestamp>\n", .{});
            return;
        }

        const timestamp = std.fmt.parseInt(i64, args[1], 10) catch {
            try stdout.print("Invalid timestamp: {s}\n", .{args[1]});
            return;
        };

        var mgr = snapshots.SnapshotManager.init(allocator, null);

        // Load snapshot
        var snap_state = mgr.loadSnapshot(timestamp) catch |err| {
            try stdout.print("Failed to load snapshot: {}\n", .{err});
            return;
        };
        defer snap_state.deinit();

        // Query live state
        var live = state_live.queryLiveState(allocator) catch |err| {
            try stdout.print("Failed to query live state: {}\n", .{err});
            return;
        };
        defer live.deinit();

        // Compare
        var diff = state_diff.compare(&snap_state, &live, allocator) catch |err| {
            try stdout.print("Failed to compare states: {}\n", .{err});
            return;
        };
        defer diff.deinit();

        if (diff.isEmpty()) {
            try stdout.print("No differences from snapshot {d}\n", .{timestamp});
        } else {
            try stdout.print("Differences from snapshot {d}:\n", .{timestamp});
            try stdout.print("-------------------------------\n", .{});
            try stdout.print("{d} changes detected\n", .{diff.changes.items.len});

            for (diff.changes.items) |change| {
                const entry = changelog.stateChangeToEntry(change);
                try entry.format(stdout);
            }
        }
    } else if (std.mem.eql(u8, subcommand, "log")) {
        // wire history log - show full changelog
        var logger = changelog.ChangeLogger.init(allocator, null);
        const entries = logger.readAll() catch |err| {
            try stdout.print("Failed to read changelog: {}\n", .{err});
            return;
        };
        defer allocator.free(entries);

        if (entries.len == 0) {
            try stdout.print("No changes recorded.\n", .{});
            return;
        }

        try stdout.print("Change Log ({d} entries)\n", .{entries.len});
        try stdout.print("-----------------------\n", .{});

        for (entries) |*entry| {
            try entry.format(stdout);
        }
    } else {
        try stdout.print("Unknown history subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, snapshot, list, diff, log\n", .{});
    }
}

fn handleNeighbor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Default to show
    var subcommand: []const u8 = "show";
    if (args.len > 0) {
        subcommand = args[0];
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

        // Filter by interface name if provided
        var filter_name: ?[]const u8 = null;
        if (args.len > 1) {
            filter_name = args[1];
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
    } else {
        try stdout.print("Unknown neighbor subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, lookup, arp\n", .{});
    }
}

fn handleTopology(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Query live state
    var live_state = state_live.queryLiveState(allocator) catch |err| {
        try stdout.print("Failed to query network state: {}\n", .{err});
        return;
    };
    defer live_state.deinit();

    // Build topology graph
    var graph = topology.TopologyGraph.buildFromState(allocator, &live_state) catch |err| {
        try stdout.print("Failed to build topology: {}\n", .{err});
        return;
    };
    defer graph.deinit();

    // Default to show
    var subcommand: []const u8 = "show";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire topology show
        try graph.displayTree(stdout);
    } else if (std.mem.eql(u8, subcommand, "path")) {
        // wire topology path <src> to <dst>
        if (args.len < 4 or !std.mem.eql(u8, args[2], "to")) {
            try stdout.print("Usage: wire topology path <src> to <dst>\n", .{});
            try stdout.print("Example: wire topology path eth0 to br0\n", .{});
            return;
        }

        const src = args[1];
        const dst = args[3];

        const path = graph.findPath(src, dst, allocator) catch |err| {
            try stdout.print("Failed to find path: {}\n", .{err});
            return;
        };

        if (path) |p| {
            defer allocator.free(p);

            try stdout.print("Path from {s} to {s}:\n\n", .{ src, dst });
            try graph.displayPath(p, stdout);
            try stdout.print("\n", .{});

            // Validate path
            var validation = graph.validatePath(p);
            defer validation.deinit();
            try validation.format(stdout);
        } else {
            try stdout.print("No path found between {s} and {s}\n", .{ src, dst });
        }
    } else if (std.mem.eql(u8, subcommand, "children")) {
        // wire topology children <interface>
        if (args.len < 2) {
            try stdout.print("Usage: wire topology children <interface>\n", .{});
            return;
        }

        const iface_name = args[1];
        const node = graph.findNodeByName(iface_name);

        if (node) |n| {
            const children = graph.getChildren(n.index, allocator) catch |err| {
                try stdout.print("Failed to get children: {}\n", .{err});
                return;
            };
            defer allocator.free(children);

            if (children.len == 0) {
                try stdout.print("{s} has no child interfaces\n", .{iface_name});
            } else {
                try stdout.print("Children of {s}:\n", .{iface_name});
                for (children) |*child| {
                    try stdout.print("  ", .{});
                    try child.format(stdout);
                    try stdout.print("\n", .{});
                }
            }
        } else {
            try stdout.print("Interface {s} not found\n", .{iface_name});
        }
    } else {
        try stdout.print("Unknown topology subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, path, children\n", .{});
    }
}

fn handleDiagnose(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Diagnose commands (all native, no external tools):\n", .{});
        try stdout.print("  diagnose ping <target>           ICMP ping\n", .{});
        try stdout.print("  diagnose trace <target>          ICMP traceroute\n", .{});
        try stdout.print("  diagnose capture [interface]     Packet capture\n", .{});
        try stdout.print("\nPing options:\n", .{});
        try stdout.print("  -c <count>    Number of pings (default: 4)\n", .{});
        try stdout.print("  -W <secs>     Timeout per packet (default: 1)\n", .{});
        try stdout.print("  -t <ttl>      Time to live (default: 64)\n", .{});
        try stdout.print("  from <iface>  Bind to interface\n", .{});
        try stdout.print("\nTrace options:\n", .{});
        try stdout.print("  -m <hops>     Max hops (default: 30)\n", .{});
        try stdout.print("  -q <probes>   Probes per hop (default: 3)\n", .{});
        try stdout.print("  -W <secs>     Timeout per probe (default: 1)\n", .{});
        try stdout.print("\nCapture options:\n", .{});
        try stdout.print("  -c <count>    Stop after N packets\n", .{});
        try stdout.print("  -t <secs>     Stop after N seconds\n", .{});
        try stdout.print("  -f <filter>   Filter: tcp, udp, icmp, port N, host X.X.X.X\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire diagnose ping 10.0.0.1\n", .{});
        try stdout.print("  wire diagnose trace 8.8.8.8\n", .{});
        try stdout.print("  wire diagnose capture eth0 -c 10\n", .{});
        try stdout.print("  wire diagnose capture eth0 -f \"tcp port 80\"\n", .{});
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "ping")) {
        try handleDiagnosePing(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "trace") or std.mem.eql(u8, subcommand, "traceroute")) {
        try handleDiagnoseTrace(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "capture") or std.mem.eql(u8, subcommand, "cap")) {
        try handleDiagnoseCapture(allocator, args[1..]);
    } else {
        try stdout.print("Unknown diagnose subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: ping, trace, capture\n", .{});
    }
}

fn handleDiagnosePing(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Usage: wire diagnose ping <target> [options]\n", .{});
        return;
    }

    const target = args[0];
    var options = native_ping.PingOptions{};

    // Parse options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "from") and i + 1 < args.len) {
            options.interface = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
            options.count = std.fmt.parseInt(u32, args[i + 1], 10) catch 4;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-W") and i + 1 < args.len) {
            options.timeout_ms = (std.fmt.parseInt(u32, args[i + 1], 10) catch 1) * 1000;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            options.ttl = std.fmt.parseInt(u8, args[i + 1], 10) catch 64;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            options.packet_size = std.fmt.parseInt(u16, args[i + 1], 10) catch 56;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-i") and i + 1 < args.len) {
            options.interval_ms = (std.fmt.parseInt(u32, args[i + 1], 10) catch 1) * 1000;
            i += 1;
        }
    }

    // Run native ping
    const result = native_ping.ping(allocator, target, options) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: raw socket requires root or CAP_NET_RAW\n", .{});
            return;
        }
        try stdout.print("Failed to run ping: {}\n", .{err});
        return;
    };

    // Display result
    try result.format(stdout);
}

fn handleDiagnoseTrace(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Usage: wire diagnose trace <target> [options]\n", .{});
        return;
    }

    const target = args[0];
    var options = native_trace.TraceOptions{};

    // Parse options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "from") and i + 1 < args.len) {
            options.interface = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            options.max_hops = std.fmt.parseInt(u8, args[i + 1], 10) catch 30;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-q") and i + 1 < args.len) {
            options.probes_per_hop = std.fmt.parseInt(u8, args[i + 1], 10) catch 3;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-W") and i + 1 < args.len) {
            options.timeout_ms = (std.fmt.parseInt(u32, args[i + 1], 10) catch 1) * 1000;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-f") and i + 1 < args.len) {
            options.initial_ttl = std.fmt.parseInt(u8, args[i + 1], 10) catch 1;
            i += 1;
        }
    }

    // Run native traceroute
    var result = native_trace.trace(allocator, target, options) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: raw socket requires root or CAP_NET_RAW\n", .{});
            return;
        }
        try stdout.print("Failed to run traceroute: {}\n", .{err});
        return;
    };
    defer result.deinit();

    // Display result
    try result.format(stdout);
}

fn handleDiagnoseCapture(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var options = native_capture.CaptureOptions{};
    var filter_str: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") and i + 1 < args.len) {
            options.count = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            options.duration_secs = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-f") and i + 1 < args.len) {
            filter_str = args[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            options.interface = arg;
        }
    }

    // Apply filter
    if (filter_str) |f| {
        const filter_opts = native_capture.parseFilter(f);
        options.filter_proto = filter_opts.filter_proto;
        options.filter_port = filter_opts.filter_port;
        options.filter_host = filter_opts.filter_host;
    }

    // Default to 10 packets if no limit specified
    if (options.count == null and options.duration_secs == null) {
        options.count = 10;
    }

    // Print header
    if (options.interface) |iface| {
        try stdout.print("Capturing on {s}", .{iface});
    } else {
        try stdout.print("Capturing on all interfaces", .{});
    }
    if (options.count) |c| {
        try stdout.print(", max {d} packets", .{c});
    }
    if (options.duration_secs) |d| {
        try stdout.print(", max {d} seconds", .{d});
    }
    try stdout.print("\n\n", .{});

    // Run capture
    const capture_stats = native_capture.capture(allocator, options, stdout) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: packet capture requires root or CAP_NET_RAW\n", .{});
            return;
        }
        if (err == error.InterfaceNotFound) {
            try stdout.print("Interface not found\n", .{});
            return;
        }
        try stdout.print("Failed to capture: {}\n", .{err});
        return;
    };

    // Print stats
    try capture_stats.format(stdout);
}

fn handlePathTrace(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len < 3) {
        try stdout.print("Usage: wire trace <interface> to <destination>\n", .{});
        try stdout.print("\nTrace network path from interface to destination IP.\n", .{});
        try stdout.print("Validates interface states, bonds, bridges, VLANs, and ARP entries.\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire trace eth0 to 10.0.0.1\n", .{});
        try stdout.print("  wire trace br0 to 192.168.1.1\n", .{});
        try stdout.print("  wire trace bond0.100 to 10.0.0.50\n", .{});
        return;
    }

    const source = args[0];

    // Expect "to" keyword
    if (args.len < 3 or !std.mem.eql(u8, args[1], "to")) {
        try stdout.print("Usage: wire trace <interface> to <destination>\n", .{});
        return;
    }

    const destination = args[2];

    // Run path trace
    var trace = path_trace.tracePath(allocator, source, destination) catch |err| {
        if (err == error.PermissionDenied) {
            try stdout.print("Permission denied: path tracing requires root\n", .{});
            return;
        }
        try stdout.print("Failed to trace path: {}\n", .{err});
        return;
    };
    defer trace.deinit();

    // Display result
    try trace.format(stdout);
}

fn handleProbe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Probe commands:\n", .{});
        try stdout.print("  probe <host> <port|service>     Test TCP connectivity\n", .{});
        try stdout.print("  probe <host> <port> --timeout <ms>  With custom timeout\n", .{});
        try stdout.print("  probe <host> scan               Scan common ports\n", .{});
        try stdout.print("  probe service <name>            Lookup service port\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire probe 10.0.0.1 22          Test SSH port\n", .{});
        try stdout.print("  wire probe 10.0.0.1 ssh         Test SSH by name\n", .{});
        try stdout.print("  wire probe 10.0.0.1 http        Test HTTP port\n", .{});
        try stdout.print("  wire probe 10.0.0.1 scan        Scan common ports\n", .{});
        try stdout.print("  wire probe service ssh          Show SSH port number\n", .{});
        return;
    }

    const first_arg = args[0];

    // wire probe service <name> - lookup service
    if (std.mem.eql(u8, first_arg, "service")) {
        if (args.len < 2) {
            try stdout.print("Usage: wire probe service <name>\n", .{});
            return;
        }
        const service_name = args[1];
        if (probe.lookupService(allocator, service_name, null) catch null) |service| {
            try stdout.print("{s}: {d}/{s}\n", .{ service.name, service.port, service.protocol.toString() });
        } else {
            try stdout.print("Service '{s}' not found in /etc/services\n", .{service_name});
        }
        return;
    }

    // wire probe <host> <port|service|scan>
    if (args.len < 2) {
        try stdout.print("Usage: wire probe <host> <port|service>\n", .{});
        return;
    }

    const target = first_arg;
    const port_or_cmd = args[1];

    // Parse timeout if provided
    var timeout_ms: u32 = 3000; // Default 3 seconds
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--timeout") or std.mem.eql(u8, args[i], "-t")) {
            timeout_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid timeout: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        }
    }

    // wire probe <host> scan - scan common ports
    if (std.mem.eql(u8, port_or_cmd, "scan")) {
        try stdout.print("Scanning {s} (common ports, timeout {d}ms)...\n\n", .{ target, timeout_ms });

        for (probe.CommonPorts.quick_scan) |port| {
            const result = probe.probeTcp(target, port, timeout_ms);
            try result.format(stdout);
        }
        return;
    }

    // Resolve port from service name or number
    const port = probe.resolvePort(allocator, port_or_cmd, .tcp) catch |err| {
        if (err == error.UnknownService) {
            try stdout.print("Unknown service: {s}\n", .{port_or_cmd});
            try stdout.print("Use a port number or a service name from /etc/services\n", .{});
        } else {
            try stdout.print("Failed to resolve port: {}\n", .{err});
        }
        return;
    };

    // Probe the port
    const result = probe.probeTcp(target, port, timeout_ms);
    try result.format(stdout);
}

fn handleValidate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Validate commands:\n", .{});
        try stdout.print("  validate config <file>              Validate configuration file\n", .{});
        try stdout.print("  validate vlan <id> on <interface>   Validate VLAN configuration\n", .{});
        try stdout.print("  validate path <iface> to <dest>     Validate network path\n", .{});
        try stdout.print("  validate service <host> <port>      Validate service connectivity\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire validate config /etc/wire/network.wire\n", .{});
        try stdout.print("  wire validate vlan 100 on eth0\n", .{});
        try stdout.print("  wire validate path eth0 to 10.0.0.1\n", .{});
        try stdout.print("  wire validate service 10.0.0.1 ssh\n", .{});
        return;
    }

    const subcommand = args[0];

    // wire validate config <file>
    if (std.mem.eql(u8, subcommand, "config")) {
        if (args.len < 2) {
            try stdout.print("Usage: wire validate config <config-file>\n", .{});
            return;
        }

        const config_path = args[1];

        var report = config_loader.validateConfig(config_path, allocator) catch |err| {
            try stdout.print("Failed to validate configuration: {}\n", .{err});
            return;
        };
        defer report.deinit(allocator);

        try stdout.print("Validation Report\n", .{});
        try stdout.print("-----------------\n", .{});
        try stdout.print("Total commands: {d}\n", .{report.total_commands});
        try stdout.print("Valid: {d}\n", .{report.valid_commands});
        try stdout.print("Errors: {d}\n", .{report.errors});

        if (report.errors > 0) {
            try stdout.print("\nErrors:\n", .{});
            for (report.error_messages) |msg| {
                try stdout.print("  - {s}\n", .{msg});
            }
            std.process.exit(1);
        } else {
            try stdout.print("\nConfiguration is valid.\n", .{});
        }
        return;
    }

    // wire validate vlan <id> on <interface>
    if (std.mem.eql(u8, subcommand, "vlan")) {
        if (args.len < 4) {
            try stdout.print("Usage: wire validate vlan <id> on <interface>\n", .{});
            return;
        }

        const vlan_id = std.fmt.parseInt(u16, args[1], 10) catch {
            try stdout.print("Invalid VLAN ID: {s}\n", .{args[1]});
            return;
        };

        // Expect "on" keyword
        if (!std.mem.eql(u8, args[2], "on")) {
            try stdout.print("Usage: wire validate vlan <id> on <interface>\n", .{});
            return;
        }

        const parent = args[3];

        try stdout.print("Validating VLAN {d} on {s}...\n\n", .{ vlan_id, parent });

        var result = validate.validateVlan(allocator, vlan_id, parent) catch |err| {
            try stdout.print("Validation failed: {}\n", .{err});
            return;
        };
        defer result.deinit();

        try result.format(stdout);
        return;
    }

    // wire validate path <iface> to <dest>
    if (std.mem.eql(u8, subcommand, "path")) {
        if (args.len < 4) {
            try stdout.print("Usage: wire validate path <interface> to <destination>\n", .{});
            return;
        }

        const source_iface = args[1];

        // Expect "to" keyword
        if (!std.mem.eql(u8, args[2], "to")) {
            try stdout.print("Usage: wire validate path <interface> to <destination>\n", .{});
            return;
        }

        const destination = args[3];

        try stdout.print("Validating path from {s} to {s}...\n\n", .{ source_iface, destination });

        var result = validate.validatePath(allocator, source_iface, destination) catch |err| {
            try stdout.print("Validation failed: {}\n", .{err});
            return;
        };
        defer result.deinit();

        try result.format(stdout);
        return;
    }

    // wire validate service <host> <port|service>
    if (std.mem.eql(u8, subcommand, "service")) {
        if (args.len < 3) {
            try stdout.print("Usage: wire validate service <host> <port|service>\n", .{});
            return;
        }

        const host = args[1];
        const port_or_service = args[2];

        try stdout.print("Validating service {s} on {s}...\n\n", .{ port_or_service, host });

        var result = validate.validateService(allocator, host, port_or_service) catch |err| {
            try stdout.print("Validation failed: {}\n", .{err});
            return;
        };
        defer result.deinit();

        try result.format(stdout);
        return;
    }

    try stdout.print("Unknown validate subcommand: {s}\n", .{subcommand});
    try stdout.print("Available: config, vlan, path, service\n", .{});
}

fn handleWatch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Watch commands:\n", .{});
        try stdout.print("  watch <host> <port|service>         Watch service connectivity\n", .{});
        try stdout.print("  watch <host> <port> --interval <ms> Set probe interval (default 1000)\n", .{});
        try stdout.print("  watch <host> <port> --alert <ms>    Alert if latency exceeds threshold\n", .{});
        try stdout.print("  watch interface <name>              Watch interface status\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire watch 10.0.0.1 ssh\n", .{});
        try stdout.print("  wire watch 10.0.0.1 80 --interval 500\n", .{});
        try stdout.print("  wire watch 10.0.0.1 443 --alert 100\n", .{});
        try stdout.print("  wire watch interface eth0\n", .{});
        return;
    }

    const first_arg = args[0];

    // wire watch interface <name>
    if (std.mem.eql(u8, first_arg, "interface")) {
        if (args.len < 2) {
            try stdout.print("Usage: wire watch interface <name>\n", .{});
            return;
        }

        const iface_name = args[1];
        var interval_ms: u32 = 1000;

        // Parse options
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--interval") or std.mem.eql(u8, args[i], "-i")) {
                interval_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    try stdout.print("Invalid interval: {s}\n", .{args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        watch.watchInterface(allocator, iface_name, interval_ms, null, stdout) catch |err| {
            try stdout.print("Watch failed: {}\n", .{err});
        };
        return;
    }

    // wire watch <host> <port|service> [options]
    if (args.len < 2) {
        try stdout.print("Usage: wire watch <host> <port|service>\n", .{});
        return;
    }

    const target = first_arg;
    const port_or_service = args[1];

    // Resolve port
    const port = probe.resolvePort(allocator, port_or_service, .tcp) catch |err| {
        if (err == error.UnknownService) {
            try stdout.print("Unknown service: {s}\n", .{port_or_service});
        } else {
            try stdout.print("Failed to resolve port: {}\n", .{err});
        }
        return;
    };

    // Parse options
    var interval_ms: u32 = 1000;
    var timeout_ms: u32 = 3000;
    var alert_threshold_ms: ?u32 = null;

    var i: usize = 2;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--interval") or std.mem.eql(u8, args[i], "-i")) {
            interval_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid interval: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--timeout") or std.mem.eql(u8, args[i], "-t")) {
            timeout_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid timeout: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--alert") or std.mem.eql(u8, args[i], "-a")) {
            alert_threshold_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                try stdout.print("Invalid alert threshold: {s}\n", .{args[i + 1]});
                return;
            };
            i += 1;
        }
    }

    const config = watch.WatchConfig{
        .target = target,
        .port = port,
        .interval_ms = interval_ms,
        .timeout_ms = timeout_ms,
        .alert_threshold_ms = alert_threshold_ms,
        .alert_on_failure = true,
        .max_iterations = null,
    };

    const watch_stats = watch.watch(config, stdout) catch |err| {
        try stdout.print("Watch failed: {}\n", .{err});
        return;
    };

    try watch_stats.format(stdout);
}

fn handleInterfaceStats(allocator: std.mem.Allocator, iface_name: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

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

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("wire {s}\n", .{version});
    try stdout.print("Low-level, declarative, continuously-supervised network configuration for Linux\n", .{});
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\wire - Network configuration tool for Linux
        \\
        \\Usage: wire <command> [options]
        \\
        \\Commands:
        \\  interface                      List all interfaces
        \\  interface <name> show          Show interface details
        \\  interface <name> set state up  Bring interface up
        \\  interface <name> set state down Bring interface down
        \\  interface <name> set mtu <n>   Set interface MTU
        \\  interface <name> address <ip>  Add IP address (e.g., 10.0.0.1/24)
        \\  interface <name> address del <ip>  Delete IP address
        \\
        \\  route                          Show routing table
        \\  route show                     Show routing table
        \\  route add <dst> via <gw>       Add route via gateway
        \\  route add <dst> dev <iface>    Add route via interface
        \\  route add default via <gw>     Add default route
        \\  route del <dst>                Delete route
        \\
        \\  bond                           List bonds (show help)
        \\  bridge                         List bridges (show help)
        \\  bridge <name> fdb              Show bridge FDB entries
        \\  bridge fdb                     Show all FDB entries
        \\  vlan                           VLAN help
        \\  veth                           Veth pair help
        \\
        \\  apply <config-file>            Apply configuration file
        \\  apply <config-file> --dry-run  Validate without applying
        \\  validate <config-file>         Validate configuration file
        \\  diff <config-file>             Compare config against live state
        \\  state                          Show current network state
        \\  events [seconds]               Monitor network events (default 10s)
        \\  reconcile <config> [--dry-run] Apply changes to match config
        \\
        \\  daemon start [config]          Start the supervision daemon
        \\  daemon stop                    Stop the daemon
        \\  daemon status                  Show daemon status
        \\  daemon reload                  Reload configuration
        \\
        \\  analyze                        Analyze network configuration
        \\
        \\  history                        Show recent changes (last 10)
        \\  history show [N]               Show last N changes
        \\  history snapshot               Create a state snapshot now
        \\  history list                   List available snapshots
        \\  history diff <timestamp>       Compare current state to snapshot
        \\  history log                    Show full change history
        \\
        \\  neighbor                       Show neighbor (ARP/NDP) table
        \\  neighbor show [interface]      Show neighbors, optionally for interface
        \\  neighbor lookup <ip>           Lookup neighbor by IP address
        \\  neighbor arp                   Show IPv4 ARP table only
        \\
        \\  topology                       Show network topology
        \\  topology show                  Display interface hierarchy
        \\  topology path <src> to <dst>   Find path between interfaces
        \\  topology children <interface>  Show child interfaces
        \\
        \\  interface <name> stats         Show interface statistics
        \\
        \\  diagnose                       Show diagnose help
        \\  diagnose ping <target>         Native ICMP ping
        \\  diagnose trace <target>        Native ICMP traceroute
        \\  diagnose capture [iface]       Native packet capture
        \\
        \\  trace <iface> to <dest>        Trace network path to destination
        \\
        \\  probe <host> <port|service>    Test TCP connectivity to service
        \\  probe <host> scan              Scan common ports
        \\  probe service <name>           Lookup service port from /etc/services
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\
        \\Examples:
        \\  wire interface
        \\  wire interface eth0 show
        \\  wire interface eth0 set state up
        \\  wire interface eth0 set mtu 9000
        \\  wire interface eth0 address 10.0.0.1/24
        \\  wire route add default via 10.0.0.254
        \\  wire analyze
        \\
    , .{});
}

test "version string" {
    try std.testing.expect(version.len > 0);
}
