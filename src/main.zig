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
const ip_rule = @import("netlink/rule.zig");
const namespace = @import("netlink/namespace.zig");
const ethtool = @import("netlink/ethtool.zig");
const tunnel = @import("netlink/tunnel.zig");
const qdisc = @import("netlink/qdisc.zig");
const stats = @import("netlink/stats.zig");
const topology = @import("analysis/topology.zig");
const native_ping = @import("plugins/native/ping.zig");
const native_trace = @import("plugins/native/traceroute.zig");
const native_capture = @import("plugins/native/capture.zig");
const path_trace = @import("diagnostics/trace.zig");
const probe = @import("diagnostics/probe.zig");
const validate = @import("diagnostics/validate.zig");
const watch = @import("diagnostics/watch.zig");
const json_output = @import("output/json.zig");
const linux = std.os.linux;

const version = "1.0.0";

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

    const first_arg = args[1];

    if (std.mem.eql(u8, first_arg, "--version") or std.mem.eql(u8, first_arg, "-v")) {
        try printVersion();
        return;
    }

    if (std.mem.eql(u8, first_arg, "--help") or std.mem.eql(u8, first_arg, "-h")) {
        try printUsage();
        return;
    }

    // Execute command (handles --json flag internally)
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

    // Check if --json flag is first, find the actual command
    const has_json = args.len > 0 and (std.mem.eql(u8, args[0], "--json") or std.mem.eql(u8, args[0], "-j"));
    const cmd_idx: usize = if (has_json) 1 else 0;

    if (cmd_idx >= args.len) {
        try printUsage();
        return;
    }

    const subject = args[cmd_idx];
    // Args after the command (e.g., "eth0 show" for "wire interface eth0 show")
    const post_cmd_args = args[cmd_idx + 1 ..];

    // Build handler args: if --json was global flag, prepend it so handlers can detect it
    var handler_args_list = std.ArrayList([]const u8).init(allocator);
    defer handler_args_list.deinit();

    if (has_json) {
        try handler_args_list.append("--json");
    }
    for (post_cmd_args) |arg| {
        try handler_args_list.append(arg);
    }
    const handler_args = handler_args_list.items;

    if (std.mem.eql(u8, subject, "interface")) {
        try handleInterface(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "route")) {
        try handleRoute(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "analyze")) {
        try handleAnalyze(allocator);
    } else if (std.mem.eql(u8, subject, "apply")) {
        try handleApply(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "validate")) {
        try handleValidate(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "bond")) {
        try handleBond(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "bridge")) {
        try handleBridge(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "vlan")) {
        try handleVlan(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "veth")) {
        try handleVeth(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "state")) {
        try handleState(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "diff")) {
        try handleDiff(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "events")) {
        try handleEvents(handler_args);
    } else if (std.mem.eql(u8, subject, "reconcile")) {
        try handleReconcile(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "daemon")) {
        try handleDaemon(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "history")) {
        try handleHistory(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "neighbor")) {
        try handleNeighbor(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "rule")) {
        try handleRule(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "netns") or std.mem.eql(u8, subject, "namespace")) {
        try handleNamespace(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "hw") or std.mem.eql(u8, subject, "hardware")) {
        try handleHardware(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "tunnel")) {
        try handleTunnel(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "tc") or std.mem.eql(u8, subject, "qdisc")) {
        try handleTc(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "topology")) {
        try handleTopology(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "diagnose")) {
        try handleDiagnose(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "trace")) {
        try handlePathTrace(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "probe")) {
        try handleProbe(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "validate")) {
        try handleValidate(allocator, handler_args);
    } else if (std.mem.eql(u8, subject, "watch")) {
        try handleWatch(allocator, handler_args);
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Unknown command: {s}\n", .{subject});
        try stderr.print("Run 'wire --help' for usage.\n", .{});
    }
}

fn handleInterface(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    // wire interface (list all)
    if (filtered_args.len == 0) {
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator);
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
                var json = json_output.JsonOutput.init(allocator);
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
                var json = json_output.JsonOutput.init(allocator);
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
        try handleInterfaceStats(allocator, iface_name);
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

fn handleRoute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    // wire route show (or just 'wire route')
    if (filtered_args.len == 0 or std.mem.eql(u8, filtered_args[0], "show")) {
        const routes = try netlink_route.getRoutes(allocator);
        defer allocator.free(routes);

        // Get interfaces for name lookup
        const interfaces = try netlink_interface.getInterfaces(allocator);
        defer allocator.free(interfaces);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator);
            try json.writeRoutes(routes, interfaces);
            return;
        }

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

    const action = filtered_args[0];

    // wire route add <dst> via <gateway>
    // wire route add <dst> dev <interface>
    // wire route add default via <gateway>
    if (std.mem.eql(u8, action, "add") and filtered_args.len >= 2) {
        const dst_str = filtered_args[1];
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
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "via") and i + 1 < filtered_args.len) {
                const gw_parsed = netlink_address.parseIPv4(filtered_args[i + 1]) catch {
                    try stdout.print("Invalid gateway: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                gateway = gw_parsed.addr;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "dev") and i + 1 < filtered_args.len) {
                const iface_name = filtered_args[i + 1];
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
    if (std.mem.eql(u8, action, "del") and filtered_args.len >= 2) {
        const dst_str = filtered_args[1];
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
        try stdout.print("Usage: wire apply <config-file> [options]\n", .{});
        try stdout.print("\nOptions:\n", .{});
        try stdout.print("  --dry-run, -n    Validate without applying changes\n", .{});
        try stdout.print("  --yes, -y        Skip confirmation prompt\n", .{});
        try stdout.print("  --force          Apply despite errors (use with caution)\n", .{});
        try stdout.print("  --strict         Fail on warnings too (for CI/CD)\n", .{});
        try stdout.print("  --staging        Relaxed validation (for staging environments)\n", .{});
        try stdout.print("  --verbose, -v    Show detailed output\n", .{});
        return;
    }

    const config_path = args[0];
    var options = config_loader.ApplyOptions{};

    // Check for flags
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            options.skip_confirmation = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, arg, "--staging")) {
            options.staging = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            options.verbose = true;
        }
    }

    // Warn about conflicting options
    if (options.force and options.strict) {
        try stdout.print("Warning: --force and --strict are conflicting options\n", .{});
        try stdout.print("  --force will apply despite errors, --strict will fail on warnings\n", .{});
        try stdout.print("  Using --force takes precedence\n\n", .{});
    }

    if (options.staging) {
        try stdout.print("Staging mode: Validation warnings will be logged but not block.\n", .{});
        try stdout.print("Unreachable gateways and missing dependencies are expected.\n\n", .{});
    }

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
            var json = json_output.JsonOutput.init(allocator);
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
            var json = json_output.JsonOutput.init(allocator);
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

fn handleRule(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    var subcommand: []const u8 = "show";
    if (filtered_args.len > 0) {
        subcommand = filtered_args[0];
    }

    if (std.mem.eql(u8, subcommand, "show") or std.mem.eql(u8, subcommand, "list")) {
        // wire rule show
        const rules = ip_rule.getRules(allocator, linux.AF.INET) catch |err| {
            try stdout.print("Failed to query IP rules: {}\n", .{err});
            return;
        };
        defer allocator.free(rules);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator);
            try json.writeRules(rules);
            return;
        }

        if (rules.len == 0) {
            try stdout.print("No IP rules found.\n", .{});
            return;
        }

        try stdout.print("IP Rules ({d} entries)\n", .{rules.len});
        try stdout.print("{s:<8} {s:<20} {s:<10} {s:<10}\n", .{ "Prio", "From", "Action", "Table" });
        try stdout.print("{s:-<8} {s:-<20} {s:-<10} {s:-<10}\n", .{ "", "", "", "" });

        for (rules) |*r| {
            var src_buf: [32]u8 = undefined;
            const src_str = r.formatSrc(&src_buf) catch "?";

            // Table name or number
            var table_str: [16]u8 = undefined;
            const table_display = if (r.table == ip_rule.RT_TABLE.LOCAL)
                "local"
            else if (r.table == ip_rule.RT_TABLE.MAIN)
                "main"
            else if (r.table == ip_rule.RT_TABLE.DEFAULT)
                "default"
            else blk: {
                break :blk std.fmt.bufPrint(&table_str, "{d}", .{r.table}) catch "?";
            };

            try stdout.print("{d:<8} {s:<20} {s:<10} {s:<10}", .{
                r.priority,
                src_str,
                r.actionName(),
                table_display,
            });

            // Show fwmark if set
            if (r.fwmark > 0) {
                try stdout.print(" fwmark 0x{x}", .{r.fwmark});
            }

            // Show iif if set
            if (r.getIifname()) |iif| {
                try stdout.print(" iif {s}", .{iif});
            }

            // Show oif if set
            if (r.getOifname()) |oif| {
                try stdout.print(" oif {s}", .{oif});
            }

            try stdout.print("\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "add")) {
        // wire rule add from <prefix> table <table> [prio <priority>]
        // wire rule add fwmark <mark> table <table> [prio <priority>]
        if (filtered_args.len < 4) {
            try stdout.print("Usage:\n", .{});
            try stdout.print("  wire rule add from <prefix> table <table> [prio <n>]\n", .{});
            try stdout.print("  wire rule add fwmark <mark> table <table> [prio <n>]\n", .{});
            try stdout.print("  wire rule add to <prefix> table <table> [prio <n>]\n", .{});
            try stdout.print("\nExamples:\n", .{});
            try stdout.print("  wire rule add from 10.0.0.0/8 table 100 prio 100\n", .{});
            try stdout.print("  wire rule add fwmark 0x1 table 100\n", .{});
            return;
        }

        var options = ip_rule.RuleOptions.init();
        var table: u32 = ip_rule.RT_TABLE.MAIN;
        var priority: u32 = 32766; // Default priority

        // Parse arguments
        var i: usize = 1;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "from") and i + 1 < filtered_args.len) {
                const prefix = ip_rule.parsePrefix(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid source prefix: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                @memcpy(options.src[0..4], &prefix.addr);
                options.src_len = prefix.len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "to") and i + 1 < filtered_args.len) {
                const prefix = ip_rule.parsePrefix(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid destination prefix: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                @memcpy(options.dst[0..4], &prefix.addr);
                options.dst_len = prefix.len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "table") and i + 1 < filtered_args.len) {
                // Check for named tables
                const table_arg = filtered_args[i + 1];
                table = if (std.mem.eql(u8, table_arg, "main"))
                    ip_rule.RT_TABLE.MAIN
                else if (std.mem.eql(u8, table_arg, "local"))
                    ip_rule.RT_TABLE.LOCAL
                else if (std.mem.eql(u8, table_arg, "default"))
                    ip_rule.RT_TABLE.DEFAULT
                else
                    std.fmt.parseInt(u32, table_arg, 10) catch {
                        try stdout.print("Invalid table: {s}\n", .{table_arg});
                        return;
                    };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                priority = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "fwmark") and i + 1 < filtered_args.len) {
                const mark_str = filtered_args[i + 1];
                // Support hex (0x...) or decimal
                options.fwmark = if (mark_str.len > 2 and std.mem.eql(u8, mark_str[0..2], "0x"))
                    std.fmt.parseInt(u32, mark_str[2..], 16) catch {
                        try stdout.print("Invalid fwmark: {s}\n", .{mark_str});
                        return;
                    }
                else
                    std.fmt.parseInt(u32, mark_str, 10) catch {
                        try stdout.print("Invalid fwmark: {s}\n", .{mark_str});
                        return;
                    };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "iif") and i + 1 < filtered_args.len) {
                const name = filtered_args[i + 1];
                const copy_len = @min(name.len, options.iifname.len);
                @memcpy(options.iifname[0..copy_len], name[0..copy_len]);
                options.iifname_len = copy_len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "oif") and i + 1 < filtered_args.len) {
                const name = filtered_args[i + 1];
                const copy_len = @min(name.len, options.oifname.len);
                @memcpy(options.oifname[0..copy_len], name[0..copy_len]);
                options.oifname_len = copy_len;
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "blackhole")) {
                options.action = ip_rule.FR_ACT.BLACKHOLE;
            } else if (std.mem.eql(u8, filtered_args[i], "unreachable")) {
                options.action = ip_rule.FR_ACT.UNREACHABLE;
            } else if (std.mem.eql(u8, filtered_args[i], "prohibit")) {
                options.action = ip_rule.FR_ACT.PROHIBIT;
            }
        }

        ip_rule.addRule(linux.AF.INET, priority, table, options) catch |err| {
            try stdout.print("Failed to add rule: {}\n", .{err});
            return;
        };

        try stdout.print("Added rule: prio {d} table {d}\n", .{ priority, table });
    } else if (std.mem.eql(u8, subcommand, "del") or std.mem.eql(u8, subcommand, "delete")) {
        // wire rule del <priority>
        if (filtered_args.len < 2) {
            try stdout.print("Usage: wire rule del <priority>\n", .{});
            try stdout.print("Example: wire rule del 100\n", .{});
            return;
        }

        const priority = std.fmt.parseInt(u32, filtered_args[1], 10) catch {
            try stdout.print("Invalid priority: {s}\n", .{filtered_args[1]});
            return;
        };

        ip_rule.deleteRule(linux.AF.INET, priority) catch |err| {
            try stdout.print("Failed to delete rule: {}\n", .{err});
            return;
        };

        try stdout.print("Deleted rule with priority {d}\n", .{priority});
    } else if (std.mem.eql(u8, subcommand, "help")) {
        try stdout.print("IP Rule commands (policy routing):\n", .{});
        try stdout.print("  rule                         Show all IP rules\n", .{});
        try stdout.print("  rule show                    Show all IP rules\n", .{});
        try stdout.print("  rule add from <prefix> ...   Add rule based on source\n", .{});
        try stdout.print("  rule add to <prefix> ...     Add rule based on destination\n", .{});
        try stdout.print("  rule add fwmark <mark> ...   Add rule based on firewall mark\n", .{});
        try stdout.print("  rule del <priority>          Delete rule by priority\n", .{});
        try stdout.print("\nOptions for add:\n", .{});
        try stdout.print("  table <name|id>    Routing table (main, local, default, or 1-252)\n", .{});
        try stdout.print("  prio <n>           Rule priority (lower = higher priority)\n", .{});
        try stdout.print("  iif <interface>    Match incoming interface\n", .{});
        try stdout.print("  oif <interface>    Match outgoing interface\n", .{});
        try stdout.print("  blackhole          Drop packets (no table lookup)\n", .{});
        try stdout.print("  unreachable        Return ICMP unreachable\n", .{});
        try stdout.print("  prohibit           Return ICMP prohibited\n", .{});
    } else {
        try stdout.print("Unknown rule subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, add, del, help\n", .{});
    }
}

fn handleNamespace(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var subcommand: []const u8 = "list";
    if (args.len > 0) {
        subcommand = args[0];
    }

    if (std.mem.eql(u8, subcommand, "list") or std.mem.eql(u8, subcommand, "show")) {
        // wire netns list
        const namespaces = namespace.listNamespaces(allocator) catch |err| {
            try stdout.print("Failed to list namespaces: {}\n", .{err});
            return;
        };
        defer allocator.free(namespaces);

        if (namespaces.len == 0) {
            try stdout.print("No named network namespaces found.\n", .{});
            try stdout.print("(Namespaces are stored in /var/run/netns/)\n", .{});
            return;
        }

        try stdout.print("Network Namespaces ({d} total):\n", .{namespaces.len});
        for (namespaces) |*ns| {
            try stdout.print("  {s}\n", .{ns.getName()});
        }
    } else if (std.mem.eql(u8, subcommand, "add") or std.mem.eql(u8, subcommand, "create")) {
        // wire netns add <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire netns add <name>\n", .{});
            try stdout.print("Example: wire netns add myns\n", .{});
            return;
        }

        const name = args[1];

        // Check if already exists
        if (namespace.namespaceExists(name)) {
            try stdout.print("Namespace '{s}' already exists.\n", .{name});
            return;
        }

        namespace.createNamespace(name) catch |err| {
            try stdout.print("Failed to create namespace: {}\n", .{err});
            return;
        };

        try stdout.print("Created network namespace: {s}\n", .{name});
    } else if (std.mem.eql(u8, subcommand, "del") or std.mem.eql(u8, subcommand, "delete")) {
        // wire netns del <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire netns del <name>\n", .{});
            return;
        }

        const name = args[1];

        if (!namespace.namespaceExists(name)) {
            try stdout.print("Namespace '{s}' does not exist.\n", .{name});
            return;
        }

        namespace.deleteNamespace(name) catch |err| {
            try stdout.print("Failed to delete namespace: {}\n", .{err});
            return;
        };

        try stdout.print("Deleted network namespace: {s}\n", .{name});
    } else if (std.mem.eql(u8, subcommand, "exec")) {
        // wire netns exec <name> <command...>
        if (args.len < 3) {
            try stdout.print("Usage: wire netns exec <name> <command> [args...]\n", .{});
            try stdout.print("Example: wire netns exec myns ip addr\n", .{});
            return;
        }

        const ns_name = args[1];
        const cmd_args = args[2..];

        if (!namespace.namespaceExists(ns_name)) {
            try stdout.print("Namespace '{s}' does not exist.\n", .{ns_name});
            return;
        }

        const result = namespace.execInNamespace(allocator, ns_name, cmd_args) catch |err| {
            try stdout.print("Failed to execute in namespace: {}\n", .{err});
            return;
        };

        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    try stdout.print("Command exited with code: {d}\n", .{code});
                }
            },
            .Signal => |sig| {
                try stdout.print("Command killed by signal: {d}\n", .{sig});
            },
            else => {},
        }
    } else if (std.mem.eql(u8, subcommand, "set")) {
        // wire netns set <interface> <namespace>
        if (args.len < 3) {
            try stdout.print("Usage: wire netns set <interface> <namespace>\n", .{});
            try stdout.print("Move an interface to a namespace.\n", .{});
            try stdout.print("Example: wire netns set veth1 myns\n", .{});
            return;
        }

        const iface_name = args[1];
        const ns_name = args[2];

        // Get interface index
        const maybe_iface = netlink_interface.getInterfaceByName(allocator, iface_name) catch |err| {
            try stdout.print("Failed to find interface: {}\n", .{err});
            return;
        };

        if (maybe_iface == null) {
            try stdout.print("Interface not found: {s}\n", .{iface_name});
            return;
        }

        if (!namespace.namespaceExists(ns_name)) {
            try stdout.print("Namespace '{s}' does not exist.\n", .{ns_name});
            return;
        }

        const if_index = maybe_iface.?.index;
        namespace.moveInterfaceToNamespace(if_index, ns_name) catch |err| {
            try stdout.print("Failed to move interface to namespace: {}\n", .{err});
            return;
        };

        try stdout.print("Moved interface '{s}' to namespace '{s}'\n", .{ iface_name, ns_name });
    } else if (std.mem.eql(u8, subcommand, "help")) {
        try stdout.print("Network Namespace commands:\n", .{});
        try stdout.print("  netns                            List all named namespaces\n", .{});
        try stdout.print("  netns list                       List all named namespaces\n", .{});
        try stdout.print("  netns add <name>                 Create a new namespace\n", .{});
        try stdout.print("  netns del <name>                 Delete a namespace\n", .{});
        try stdout.print("  netns exec <name> <cmd> [args]   Execute command in namespace\n", .{});
        try stdout.print("  netns set <interface> <name>     Move interface to namespace\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire netns add isolated\n", .{});
        try stdout.print("  wire netns set veth1 isolated\n", .{});
        try stdout.print("  wire netns exec isolated ip addr\n", .{});
        try stdout.print("  wire netns del isolated\n", .{});
    } else {
        try stdout.print("Unknown netns subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: list, add, del, exec, set, help\n", .{});
    }
}

fn handleHardware(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    if (filtered_args.len < 1) {
        try stdout.print("Usage: wire hw <interface> [show|ring|coalesce]\n", .{});
        try stdout.print("\nCommands:\n", .{});
        try stdout.print("  wire hw <interface>              Show hardware info\n", .{});
        try stdout.print("  wire hw <interface> show         Show driver and hardware info\n", .{});
        try stdout.print("  wire hw <interface> ring         Show ring buffer settings\n", .{});
        try stdout.print("  wire hw <interface> ring set rx <n> tx <n>\n", .{});
        try stdout.print("  wire hw <interface> coalesce     Show interrupt coalescing\n", .{});
        try stdout.print("  wire hw <interface> coalesce set rx <usecs> tx <usecs>\n", .{});
        return;
    }

    const iface_name = filtered_args[0];

    if (std.mem.eql(u8, iface_name, "help")) {
        try stdout.print("Hardware Tuning commands:\n", .{});
        try stdout.print("  wire hw <interface>              Show hardware info\n", .{});
        try stdout.print("  wire hw <interface> show         Show driver and hardware info\n", .{});
        try stdout.print("  wire hw <interface> ring         Show ring buffer settings\n", .{});
        try stdout.print("  wire hw <interface> ring set rx <n> tx <n>\n", .{});
        try stdout.print("  wire hw <interface> coalesce     Show interrupt coalescing\n", .{});
        try stdout.print("  wire hw <interface> coalesce set rx <usecs> tx <usecs>\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire hw eth0                     Show eth0 hardware info\n", .{});
        try stdout.print("  wire hw eth0 ring                Show eth0 ring buffers\n", .{});
        try stdout.print("  wire hw eth0 ring set rx 4096    Set RX ring to 4096\n", .{});
        return;
    }

    var subcommand: []const u8 = "show";
    if (filtered_args.len > 1) {
        subcommand = filtered_args[1];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire hw <interface> show
        try stdout.print("Interface: {s}\n", .{iface_name});

        // Driver info
        const drv = ethtool.getDriverInfo(iface_name) catch |err| {
            try stdout.print("  Driver info: unavailable ({s})\n", .{@errorName(err)});
            return;
        };

        try stdout.print("  Driver: {s}\n", .{drv.getDriver()});
        if (drv.version_len > 0) {
            try stdout.print("  Version: {s}\n", .{drv.getVersion()});
        }
        if (drv.firmware_len > 0) {
            try stdout.print("  Firmware: {s}\n", .{drv.getFirmware()});
        }
        if (drv.bus_len > 0) {
            try stdout.print("  Bus: {s}\n", .{drv.getBus()});
        }

        // Link status
        const link = ethtool.getLinkStatus(iface_name) catch false;
        try stdout.print("  Link detected: {s}\n", .{if (link) "yes" else "no"});

        // Ring buffers
        if (ethtool.getRingParams(iface_name)) |ring| {
            try stdout.print("\n  Ring buffers:\n", .{});
            try stdout.print("    RX: {d}/{d}\n", .{ ring.rx_current, ring.rx_max });
            try stdout.print("    TX: {d}/{d}\n", .{ ring.tx_current, ring.tx_max });
        } else |_| {}

        // Coalesce
        if (ethtool.getCoalesceParams(iface_name)) |coal| {
            try stdout.print("\n  Coalescing:\n", .{});
            try stdout.print("    RX usecs: {d}, frames: {d}\n", .{ coal.rx_usecs, coal.rx_frames });
            try stdout.print("    TX usecs: {d}, frames: {d}\n", .{ coal.tx_usecs, coal.tx_frames });
            try stdout.print("    Adaptive RX: {s}, TX: {s}\n", .{
                if (coal.adaptive_rx) "on" else "off",
                if (coal.adaptive_tx) "on" else "off",
            });
        } else |_| {}
    } else if (std.mem.eql(u8, subcommand, "ring")) {
        // wire hw <interface> ring [set rx <n> tx <n>]
        if (filtered_args.len > 2 and std.mem.eql(u8, filtered_args[2], "set")) {
            // Parse set options
            var rx: ?u32 = null;
            var tx: ?u32 = null;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rx") and i + 1 < filtered_args.len) {
                    rx = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid RX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "tx") and i + 1 < filtered_args.len) {
                    tx = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid TX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rx == null and tx == null) {
                try stdout.print("No values specified. Usage: wire hw <if> ring set rx <n> tx <n>\n", .{});
                return;
            }

            ethtool.setRingParams(iface_name, rx, tx) catch |err| {
                try stdout.print("Failed to set ring parameters: {s}\n", .{@errorName(err)});
                return;
            };

            try stdout.print("Ring parameters updated:\n", .{});
            if (rx) |r| try stdout.print("  RX: {d}\n", .{r});
            if (tx) |t| try stdout.print("  TX: {d}\n", .{t});
        } else {
            // Show ring params
            const ring = ethtool.getRingParams(iface_name) catch |err| {
                if (use_json) {
                    try stdout.print("{{\"error\": \"{s}\"}}\n", .{@errorName(err)});
                } else {
                    try stdout.print("Failed to get ring parameters: {s}\n", .{@errorName(err)});
                }
                return;
            };

            if (use_json) {
                try stdout.print("{{\n", .{});
                try stdout.print("  \"interface\": \"{s}\",\n", .{iface_name});
                try stdout.print("  \"rx_current\": {d},\n", .{ring.rx_current});
                try stdout.print("  \"rx_max\": {d},\n", .{ring.rx_max});
                try stdout.print("  \"tx_current\": {d},\n", .{ring.tx_current});
                try stdout.print("  \"tx_max\": {d}\n", .{ring.tx_max});
                try stdout.print("}}\n", .{});
            } else {
                try stdout.print("Ring parameters for {s}:\n", .{iface_name});
                try stdout.print("  RX:  current {d}, max {d}\n", .{ ring.rx_current, ring.rx_max });
                try stdout.print("  TX:  current {d}, max {d}\n", .{ ring.tx_current, ring.tx_max });
            }
        }
    } else if (std.mem.eql(u8, subcommand, "coalesce")) {
        // wire hw <interface> coalesce [set rx <usecs> tx <usecs>]
        if (filtered_args.len > 2 and std.mem.eql(u8, filtered_args[2], "set")) {
            // Parse set options
            var rx_usecs: ?u32 = null;
            var tx_usecs: ?u32 = null;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rx") and i + 1 < filtered_args.len) {
                    rx_usecs = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid RX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "tx") and i + 1 < filtered_args.len) {
                    tx_usecs = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid TX value: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rx_usecs == null and tx_usecs == null) {
                try stdout.print("No values specified. Usage: wire hw <if> coalesce set rx <usecs> tx <usecs>\n", .{});
                return;
            }

            ethtool.setCoalesceParams(iface_name, rx_usecs, tx_usecs) catch |err| {
                try stdout.print("Failed to set coalesce parameters: {s}\n", .{@errorName(err)});
                return;
            };

            try stdout.print("Coalesce parameters updated:\n", .{});
            if (rx_usecs) |r| try stdout.print("  RX: {d} usecs\n", .{r});
            if (tx_usecs) |t| try stdout.print("  TX: {d} usecs\n", .{t});
        } else {
            // Show coalesce params
            const coal = ethtool.getCoalesceParams(iface_name) catch |err| {
                if (use_json) {
                    try stdout.print("{{\"error\": \"{s}\"}}\n", .{@errorName(err)});
                } else {
                    try stdout.print("Failed to get coalesce parameters: {s}\n", .{@errorName(err)});
                }
                return;
            };

            if (use_json) {
                try stdout.print("{{\n", .{});
                try stdout.print("  \"interface\": \"{s}\",\n", .{iface_name});
                try stdout.print("  \"rx_usecs\": {d},\n", .{coal.rx_usecs});
                try stdout.print("  \"rx_frames\": {d},\n", .{coal.rx_frames});
                try stdout.print("  \"tx_usecs\": {d},\n", .{coal.tx_usecs});
                try stdout.print("  \"tx_frames\": {d},\n", .{coal.tx_frames});
                try stdout.print("  \"adaptive_rx\": {s},\n", .{if (coal.adaptive_rx) "true" else "false"});
                try stdout.print("  \"adaptive_tx\": {s}\n", .{if (coal.adaptive_tx) "true" else "false"});
                try stdout.print("}}\n", .{});
            } else {
                try stdout.print("Coalesce parameters for {s}:\n", .{iface_name});
                try stdout.print("  RX: {d} usecs, {d} frames\n", .{ coal.rx_usecs, coal.rx_frames });
                try stdout.print("  TX: {d} usecs, {d} frames\n", .{ coal.tx_usecs, coal.tx_frames });
                try stdout.print("  Adaptive RX: {s}\n", .{if (coal.adaptive_rx) "on" else "off"});
                try stdout.print("  Adaptive TX: {s}\n", .{if (coal.adaptive_tx) "on" else "off"});
            }
        }
    } else {
        try stdout.print("Unknown hw subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, ring, coalesce\n", .{});
    }
}

fn handleTunnel(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Filter out --json flag (JSON output not yet implemented for tunnel commands)
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    if (filtered_args.len < 1) {
        try stdout.print("Usage: wire tunnel <type> <name> [options...]\n", .{});
        try stdout.print("\nOverlay Tunnels:\n", .{});
        try stdout.print("  vxlan <name> vni <id> [local <ip>] [group <ip>] [port <port>]\n", .{});
        try stdout.print("  geneve <name> vni <id> [remote <ip>] [port <port>]\n", .{});
        try stdout.print("\nPoint-to-Point Tunnels:\n", .{});
        try stdout.print("  gre <name> local <ip> remote <ip> [key <n>] [ttl <n>]\n", .{});
        try stdout.print("  gretap <name> local <ip> remote <ip> [key <n>]\n", .{});
        try stdout.print("  ipip <name> local <ip> remote <ip> [ttl <n>]\n", .{});
        try stdout.print("  sit <name> local <ip> remote <ip> [ttl <n>]    (IPv6-in-IPv4)\n", .{});
        try stdout.print("\nEncrypted Tunnels:\n", .{});
        try stdout.print("  wireguard <name>                  Create WireGuard interface\n", .{});
        try stdout.print("\nManagement:\n", .{});
        try stdout.print("  delete <name>                     Delete tunnel interface\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire tunnel vxlan vxlan100 vni 100 local 10.0.0.1\n", .{});
        try stdout.print("  wire tunnel geneve geneve1 vni 100 remote 10.0.0.2\n", .{});
        try stdout.print("  wire tunnel ipip tun0 local 10.0.0.1 remote 10.0.0.2\n", .{});
        try stdout.print("  wire tunnel wireguard wg0\n", .{});
        return;
    }

    const tunnel_type = filtered_args[0];

    if (std.mem.eql(u8, tunnel_type, "help")) {
        try stdout.print("Tunnel commands:\n", .{});
        try stdout.print("\n  wire tunnel vxlan <name> vni <id> [options...]\n", .{});
        try stdout.print("    VXLAN overlay network. Options: local <ip>, group <ip>, port <port>\n", .{});
        try stdout.print("\n  wire tunnel geneve <name> vni <id> [options...]\n", .{});
        try stdout.print("    GENEVE overlay network. Options: remote <ip>, port <port>, ttl <n>\n", .{});
        try stdout.print("\n  wire tunnel gre <name> local <ip> remote <ip> [options...]\n", .{});
        try stdout.print("    GRE tunnel (Layer 3). Options: key <n>, ttl <n>\n", .{});
        try stdout.print("\n  wire tunnel gretap <name> local <ip> remote <ip> [options...]\n", .{});
        try stdout.print("    GRE TAP (Layer 2 over GRE). Options: key <n>, ttl <n>\n", .{});
        try stdout.print("\n  wire tunnel ipip <name> local <ip> remote <ip> [ttl <n>]\n", .{});
        try stdout.print("    IP-in-IP tunnel (IPv4 over IPv4)\n", .{});
        try stdout.print("\n  wire tunnel sit <name> local <ip> remote <ip> [ttl <n>]\n", .{});
        try stdout.print("    SIT tunnel (IPv6 over IPv4, for 6in4 tunneling)\n", .{});
        try stdout.print("\n  wire tunnel wireguard <name>\n", .{});
        try stdout.print("    WireGuard interface (use 'wg' tool for key/peer config)\n", .{});
        try stdout.print("\n  wire tunnel delete <name>\n", .{});
        try stdout.print("    Delete a tunnel interface\n", .{});
        return;
    }

    if (std.mem.eql(u8, tunnel_type, "vxlan")) {
        // wire tunnel vxlan <name> vni <id> [local <ip>] [group <ip>] [port <port>]
        if (args.len < 4) {
            try stdout.print("Usage: wire tunnel vxlan <name> vni <id> [options...]\n", .{});
            try stdout.print("Options: local <ip>, group <ip>, port <port>, learning, nolearning\n", .{});
            return;
        }

        const name = filtered_args[1];
        var options = tunnel.VxlanOptions{};

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "vni") and i + 1 < filtered_args.len) {
                options.vni = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid VNI: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                options.local = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "group") and i + 1 < filtered_args.len) {
                options.group = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid group IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "port") and i + 1 < filtered_args.len) {
                options.port = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid port: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "learning")) {
                options.learning = true;
            } else if (std.mem.eql(u8, filtered_args[i], "nolearning")) {
                options.learning = false;
            }
        }

        tunnel.createVxlan(name, options) catch |err| {
            try stdout.print("Failed to create VXLAN: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Created VXLAN interface: {s} (VNI {d})\n", .{ name, options.vni });
    } else if (std.mem.eql(u8, tunnel_type, "gre")) {
        // wire tunnel gre <name> local <ip> remote <ip> [key <n>]
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel gre <name> local <ip> remote <ip> [key <n>] [ttl <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var key: ?u32 = null;
        var ttl: u8 = 64;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "key") and i + 1 < filtered_args.len) {
                key = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid key: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "ttl") and i + 1 < filtered_args.len) {
                ttl = std.fmt.parseInt(u8, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.GreOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .key = key,
            .ttl = ttl,
        };

        tunnel.createGre(name, options) catch |err| {
            try stdout.print("Failed to create GRE tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created GRE tunnel: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "gretap")) {
        // wire tunnel gretap <name> local <ip> remote <ip> [key <n>]
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel gretap <name> local <ip> remote <ip> [key <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var key: ?u32 = null;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "key") and i + 1 < filtered_args.len) {
                key = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid key: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.GreOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .key = key,
        };

        tunnel.createGretap(name, options) catch |err| {
            try stdout.print("Failed to create GRE TAP: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created GRE TAP: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "geneve")) {
        // wire tunnel geneve <name> vni <id> [remote <ip>] [port <port>]
        if (filtered_args.len < 4) {
            try stdout.print("Usage: wire tunnel geneve <name> vni <id> [remote <ip>] [port <port>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var options = tunnel.GeneveOptions{};

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "vni") and i + 1 < filtered_args.len) {
                options.vni = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid VNI: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                options.remote = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "port") and i + 1 < filtered_args.len) {
                options.port = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid port: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "ttl") and i + 1 < filtered_args.len) {
                options.ttl = std.fmt.parseInt(u8, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        tunnel.createGeneve(name, options) catch |err| {
            try stdout.print("Failed to create GENEVE tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Created GENEVE tunnel: {s} (VNI {d}, port {d})\n", .{ name, options.vni, options.port });
    } else if (std.mem.eql(u8, tunnel_type, "ipip")) {
        // wire tunnel ipip <name> local <ip> remote <ip>
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel ipip <name> local <ip> remote <ip> [ttl <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var ttl: u8 = 64;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "ttl") and i + 1 < filtered_args.len) {
                ttl = std.fmt.parseInt(u8, filtered_args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.IpipOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .ttl = ttl,
        };

        tunnel.createIpip(name, options) catch |err| {
            try stdout.print("Failed to create IP-in-IP tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created IP-in-IP tunnel: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "sit")) {
        // wire tunnel sit <name> local <ip> remote <ip>
        if (filtered_args.len < 6) {
            try stdout.print("Usage: wire tunnel sit <name> local <ip> remote <ip> [ttl <n>]\n", .{});
            return;
        }

        const name = filtered_args[1];
        var local_ip: ?[4]u8 = null;
        var remote_ip: ?[4]u8 = null;
        var ttl: u8 = 64;

        // Parse options
        var i: usize = 2;
        while (i < filtered_args.len) : (i += 1) {
            if (std.mem.eql(u8, filtered_args[i], "local") and i + 1 < filtered_args.len) {
                local_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid local IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, filtered_args[i], "remote") and i + 1 < filtered_args.len) {
                remote_ip = tunnel.parseIPv4(filtered_args[i + 1]) orelse {
                    try stdout.print("Invalid remote IP: {s}\n", .{filtered_args[i + 1]});
                    return;
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "ttl") and i + 1 < args.len) {
                ttl = std.fmt.parseInt(u8, args[i + 1], 10) catch {
                    try stdout.print("Invalid TTL: {s}\n", .{args[i + 1]});
                    return;
                };
                i += 1;
            }
        }

        if (local_ip == null or remote_ip == null) {
            try stdout.print("Both local and remote IP addresses are required.\n", .{});
            return;
        }

        const options = tunnel.IpipOptions{
            .local = local_ip.?,
            .remote = remote_ip.?,
            .ttl = ttl,
        };

        tunnel.createSit(name, options) catch |err| {
            try stdout.print("Failed to create SIT tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        var local_buf: [16]u8 = undefined;
        var remote_buf: [16]u8 = undefined;
        const local_str = tunnel.formatIPv4(local_ip.?, &local_buf) catch "?";
        const remote_str = tunnel.formatIPv4(remote_ip.?, &remote_buf) catch "?";
        try stdout.print("Created SIT tunnel: {s} ({s} -> {s})\n", .{ name, local_str, remote_str });
    } else if (std.mem.eql(u8, tunnel_type, "wireguard") or std.mem.eql(u8, tunnel_type, "wg")) {
        // wire tunnel wireguard <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire tunnel wireguard <name>\n", .{});
            try stdout.print("\nNote: This creates the interface only. Use 'wg' tool for peer configuration.\n", .{});
            return;
        }

        const name = args[1];

        tunnel.createWireguard(name) catch |err| {
            try stdout.print("Failed to create WireGuard interface: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Created WireGuard interface: {s}\n", .{name});
        try stdout.print("Use 'wg set {s} ...' to configure keys and peers\n", .{name});
    } else if (std.mem.eql(u8, tunnel_type, "delete") or std.mem.eql(u8, tunnel_type, "del")) {
        // wire tunnel delete <name>
        if (args.len < 2) {
            try stdout.print("Usage: wire tunnel delete <name>\n", .{});
            return;
        }

        const name = args[1];
        tunnel.deleteTunnel(name) catch |err| {
            try stdout.print("Failed to delete tunnel: {s}\n", .{@errorName(err)});
            return;
        };

        try stdout.print("Deleted tunnel: {s}\n", .{name});
    } else {
        try stdout.print("Unknown tunnel type: {s}\n", .{tunnel_type});
        try stdout.print("Available: vxlan, gre, gretap, geneve, ipip, sit, wireguard, delete\n", .{});
    }
}

fn handleTc(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const use_json = json_output.hasJsonFlag(args);
    const filtered_args = try json_output.filterJsonFlag(allocator, args);
    defer allocator.free(filtered_args);

    if (filtered_args.len < 1) {
        try stdout.print("Usage: wire tc <interface> [show|add|del|class|filter]\n", .{});
        try stdout.print("\nQdisc Commands:\n", .{});
        try stdout.print("  wire tc <interface>                      Show qdiscs\n", .{});
        try stdout.print("  wire tc <interface> add pfifo [limit <n>]\n", .{});
        try stdout.print("  wire tc <interface> add fq_codel          Fair queuing with CoDel\n", .{});
        try stdout.print("  wire tc <interface> add tbf rate <bps> burst <bytes> [latency <us>]\n", .{});
        try stdout.print("  wire tc <interface> add htb [default <class>]  Hierarchical Token Bucket\n", .{});
        try stdout.print("  wire tc <interface> del                   Delete root qdisc\n", .{});
        try stdout.print("\nClass Commands (for HTB):\n", .{});
        try stdout.print("  wire tc <interface> class                 Show classes\n", .{});
        try stdout.print("  wire tc <interface> class add <id> rate <r> [ceil <r>] [prio <n>]\n", .{});
        try stdout.print("  wire tc <interface> class del <id>        Delete class\n", .{});
        try stdout.print("\nFilter Commands:\n", .{});
        try stdout.print("  wire tc <interface> filter                Show filters\n", .{});
        try stdout.print("  wire tc <interface> filter add u32 match ip dst <ip/mask> flowid <id>\n", .{});
        try stdout.print("  wire tc <interface> filter add fw handle <mark> classid <id>\n", .{});
        try stdout.print("  wire tc <interface> filter del prio <n>   Delete filter\n", .{});
        try stdout.print("\nExamples:\n", .{});
        try stdout.print("  wire tc eth0 add htb default 10           HTB for class-based shaping\n", .{});
        try stdout.print("  wire tc eth0 class add 1:10 rate 10mbit   Add class with 10mbit rate\n", .{});
        try stdout.print("  wire tc eth0 filter add u32 match ip dst 10.0.0.0/8 flowid 1:10\n", .{});
        return;
    }

    const iface_name = filtered_args[0];

    if (std.mem.eql(u8, iface_name, "help")) {
        try stdout.print("Traffic Control (tc) commands:\n", .{});
        try stdout.print("\n  wire tc <interface>                Show qdiscs on interface\n", .{});
        try stdout.print("\n  wire tc <interface> add <type> [options]\n", .{});
        try stdout.print("    Types:\n", .{});
        try stdout.print("      pfifo                          Simple FIFO queue\n", .{});
        try stdout.print("      fq_codel                       Fair queuing + CoDel AQM\n", .{});
        try stdout.print("      tbf rate <r> burst <b>         Token bucket for rate limiting\n", .{});
        try stdout.print("      htb [default <class>]          Hierarchical Token Bucket (for classes)\n", .{});
        try stdout.print("\n  wire tc <interface> del            Delete root qdisc\n", .{});
        try stdout.print("\n  wire tc <interface> class          Show classes on interface\n", .{});
        try stdout.print("  wire tc <interface> class add <classid> rate <r> [ceil <r>] [prio <n>]\n", .{});
        try stdout.print("  wire tc <interface> class del <classid>\n", .{});
        try stdout.print("\n  wire tc <interface> filter         Show filters on interface\n", .{});
        try stdout.print("  wire tc <interface> filter add u32 match ip dst <ip/mask> flowid <classid>\n", .{});
        try stdout.print("  wire tc <interface> filter add fw handle <mark> classid <classid>\n", .{});
        try stdout.print("  wire tc <interface> filter del prio <n>\n", .{});
        try stdout.print("\nClass/filter IDs: format is major:minor (e.g., 1:10, 1:20)\n", .{});
        try stdout.print("Rate units: bps, kbit, mbit, gbit\n", .{});
        return;
    }

    // Get interface index
    const maybe_iface = netlink_interface.getInterfaceByName(allocator, iface_name) catch |err| {
        try stdout.print("Failed to find interface: {}\n", .{err});
        return;
    };

    if (maybe_iface == null) {
        try stdout.print("Interface not found: {s}\n", .{iface_name});
        return;
    }

    const if_index = maybe_iface.?.index;

    // Default to show
    var subcommand: []const u8 = "show";
    if (filtered_args.len > 1) {
        subcommand = filtered_args[1];
    }

    if (std.mem.eql(u8, subcommand, "show")) {
        // wire tc <interface> show
        const qdiscs = qdisc.getQdiscs(allocator, if_index) catch |err| {
            try stdout.print("Failed to get qdiscs: {}\n", .{err});
            return;
        };
        defer allocator.free(qdiscs);

        if (use_json) {
            var json = json_output.JsonOutput.init(allocator);
            try json.writeQdiscs(qdiscs);
            return;
        }

        if (qdiscs.len == 0) {
            try stdout.print("No qdiscs found on {s}\n", .{iface_name});
            return;
        }

        try stdout.print("Qdiscs on {s}:\n", .{iface_name});
        try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{ "Handle", "Parent", "Type" });
        try stdout.print("{s:-<12} {s:-<12} {s:-<12}\n", .{ "", "", "" });

        for (qdiscs) |*q| {
            var handle_buf: [16]u8 = undefined;
            var parent_buf: [16]u8 = undefined;
            const handle_str = q.formatHandle(&handle_buf) catch "?";
            const parent_str = q.formatParent(&parent_buf) catch "?";

            try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{
                handle_str,
                parent_str,
                q.getKind(),
            });
        }
    } else if (std.mem.eql(u8, subcommand, "add")) {
        // wire tc <interface> add <type> [options]
        if (filtered_args.len < 3) {
            try stdout.print("Usage: wire tc <interface> add <type> [options]\n", .{});
            try stdout.print("Types: pfifo, fq_codel, tbf, htb\n", .{});
            return;
        }

        const qdisc_type = filtered_args[2];

        if (std.mem.eql(u8, qdisc_type, "pfifo")) {
            // wire tc <interface> add pfifo [limit <n>]
            var limit: ?u32 = null;
            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "limit") and i + 1 < filtered_args.len) {
                    limit = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid limit: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            qdisc.addPfifoQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT, limit) catch |err| {
                try stdout.print("Failed to add pfifo qdisc: {}\n", .{err});
                return;
            };

            try stdout.print("Added pfifo qdisc to {s}\n", .{iface_name});
        } else if (std.mem.eql(u8, qdisc_type, "fq_codel")) {
            // wire tc <interface> add fq_codel
            qdisc.addFqCodelQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT) catch |err| {
                try stdout.print("Failed to add fq_codel qdisc: {}\n", .{err});
                return;
            };

            try stdout.print("Added fq_codel qdisc to {s}\n", .{iface_name});
        } else if (std.mem.eql(u8, qdisc_type, "tbf")) {
            // wire tc <interface> add tbf rate <bps> burst <bytes> [latency <us>]
            var rate_bps: ?u64 = null;
            var burst: ?u32 = null;
            var latency_us: u32 = 50000; // 50ms default

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rate") and i + 1 < filtered_args.len) {
                    rate_bps = parseRate(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid rate: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "burst") and i + 1 < filtered_args.len) {
                    burst = parseSize(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid burst: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "latency") and i + 1 < filtered_args.len) {
                    latency_us = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid latency: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rate_bps == null or burst == null) {
                try stdout.print("Both rate and burst are required for tbf.\n", .{});
                try stdout.print("Example: wire tc eth0 add tbf rate 10mbit burst 32k\n", .{});
                return;
            }

            qdisc.addTbfQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT, rate_bps.?, burst.?, latency_us) catch |err| {
                try stdout.print("Failed to add tbf qdisc: {}\n", .{err});
                return;
            };

            try stdout.print("Added tbf qdisc to {s} (rate {d} bps, burst {d} bytes)\n", .{ iface_name, rate_bps.?, burst.? });
        } else if (std.mem.eql(u8, qdisc_type, "htb")) {
            // wire tc <interface> add htb [default <classid>]
            var default_class: ?u32 = null;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "default") and i + 1 < filtered_args.len) {
                    default_class = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid default class: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            qdisc.addHtbQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT, default_class) catch |err| {
                try stdout.print("Failed to add htb qdisc: {}\n", .{err});
                return;
            };

            if (default_class) |dc| {
                try stdout.print("Added htb qdisc to {s} (default class 1:{d})\n", .{ iface_name, dc });
            } else {
                try stdout.print("Added htb qdisc to {s}\n", .{iface_name});
            }
        } else {
            try stdout.print("Unknown qdisc type: {s}\n", .{qdisc_type});
            try stdout.print("Available: pfifo, fq_codel, tbf, htb\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "del") or std.mem.eql(u8, subcommand, "delete")) {
        // wire tc <interface> del
        qdisc.deleteQdisc(if_index, qdisc.TC_H.make(1, 0), qdisc.TC_H.ROOT) catch |err| {
            try stdout.print("Failed to delete qdisc: {}\n", .{err});
            return;
        };

        try stdout.print("Deleted root qdisc from {s}\n", .{iface_name});
    } else if (std.mem.eql(u8, subcommand, "class")) {
        // wire tc <interface> class [show|add|del]
        var class_cmd: []const u8 = "show";
        if (filtered_args.len > 2) {
            class_cmd = filtered_args[2];
        }

        if (std.mem.eql(u8, class_cmd, "show")) {
            // wire tc <interface> class show
            const classes = qdisc.getClasses(allocator, if_index) catch |err| {
                try stdout.print("Failed to get classes: {}\n", .{err});
                return;
            };
            defer allocator.free(classes);

            if (classes.len == 0) {
                try stdout.print("No classes found on {s}\n", .{iface_name});
                return;
            }

            try stdout.print("Classes on {s}:\n", .{iface_name});
            try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{ "Class ID", "Parent", "Type" });
            try stdout.print("{s:-<12} {s:-<12} {s:-<12}\n", .{ "", "", "" });

            for (classes) |*c| {
                var handle_buf: [16]u8 = undefined;
                var parent_buf: [16]u8 = undefined;
                const handle_str = c.formatHandle(&handle_buf) catch "?";
                const parent_str = c.formatParent(&parent_buf) catch "?";

                try stdout.print("{s:<12} {s:<12} {s:<12}\n", .{
                    handle_str,
                    parent_str,
                    c.getKind(),
                });
            }
        } else if (std.mem.eql(u8, class_cmd, "add")) {
            // wire tc <interface> class add <classid> rate <rate> [ceil <rate>] [prio <n>]
            if (filtered_args.len < 6) {
                try stdout.print("Usage: wire tc <interface> class add <classid> rate <rate> [ceil <rate>] [prio <n>]\n", .{});
                try stdout.print("\nOptions:\n", .{});
                try stdout.print("  classid   Class ID in format major:minor (e.g., 1:10)\n", .{});
                try stdout.print("  rate      Guaranteed rate (e.g., 10mbit, 1gbit)\n", .{});
                try stdout.print("  ceil      Maximum rate (defaults to rate)\n", .{});
                try stdout.print("  prio      Priority 0-7 (lower = higher priority)\n", .{});
                try stdout.print("\nExample:\n", .{});
                try stdout.print("  wire tc eth0 class add 1:10 rate 10mbit ceil 100mbit prio 1\n", .{});
                return;
            }

            const classid_str = filtered_args[3];
            const classid = parseClassId(classid_str) orelse {
                try stdout.print("Invalid class ID: {s}\n", .{classid_str});
                try stdout.print("Expected format: major:minor (e.g., 1:10)\n", .{});
                return;
            };

            var rate_bps: ?u64 = null;
            var ceil_bps: u64 = 0;
            var prio: u32 = 0;
            var parent = qdisc.TC_H.make(1, 0); // Default parent is root qdisc 1:0

            var i: usize = 4;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "rate") and i + 1 < filtered_args.len) {
                    rate_bps = parseRate(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid rate: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "ceil") and i + 1 < filtered_args.len) {
                    ceil_bps = parseRate(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid ceil: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                    prio = std.fmt.parseInt(u32, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "parent") and i + 1 < filtered_args.len) {
                    parent = parseClassId(filtered_args[i + 1]) orelse {
                        try stdout.print("Invalid parent: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                }
            }

            if (rate_bps == null) {
                try stdout.print("Rate is required for class.\n", .{});
                try stdout.print("Example: wire tc eth0 class add 1:10 rate 10mbit\n", .{});
                return;
            }

            qdisc.addHtbClass(if_index, classid, parent, rate_bps.?, ceil_bps, prio) catch |err| {
                try stdout.print("Failed to add class: {}\n", .{err});
                return;
            };

            const major = qdisc.TC_H.getMajor(classid);
            const minor = qdisc.TC_H.getMinor(classid);
            try stdout.print("Added HTB class {d}:{d} on {s} (rate {d} bps)\n", .{ major, minor, iface_name, rate_bps.? });
        } else if (std.mem.eql(u8, class_cmd, "del") or std.mem.eql(u8, class_cmd, "delete")) {
            // wire tc <interface> class del <classid>
            if (filtered_args.len < 4) {
                try stdout.print("Usage: wire tc <interface> class del <classid>\n", .{});
                try stdout.print("Example: wire tc eth0 class del 1:10\n", .{});
                return;
            }

            const classid_str = filtered_args[3];
            const classid = parseClassId(classid_str) orelse {
                try stdout.print("Invalid class ID: {s}\n", .{classid_str});
                try stdout.print("Expected format: major:minor (e.g., 1:10)\n", .{});
                return;
            };

            qdisc.deleteClass(if_index, classid) catch |err| {
                try stdout.print("Failed to delete class: {}\n", .{err});
                return;
            };

            const major = qdisc.TC_H.getMajor(classid);
            const minor = qdisc.TC_H.getMinor(classid);
            try stdout.print("Deleted class {d}:{d} from {s}\n", .{ major, minor, iface_name });
        } else {
            try stdout.print("Unknown class subcommand: {s}\n", .{class_cmd});
            try stdout.print("Available: show, add, del\n", .{});
        }
    } else if (std.mem.eql(u8, subcommand, "filter")) {
        // wire tc <interface> filter [show|add|del]
        var filter_cmd: []const u8 = "show";
        if (filtered_args.len > 2) {
            filter_cmd = filtered_args[2];
        }

        if (std.mem.eql(u8, filter_cmd, "show")) {
            // wire tc <interface> filter show
            const filters = qdisc.getFilters(allocator, if_index, qdisc.TC_H.make(1, 0)) catch |err| {
                try stdout.print("Failed to get filters: {}\n", .{err});
                return;
            };
            defer allocator.free(filters);

            if (filters.len == 0) {
                try stdout.print("No filters found on {s}\n", .{iface_name});
                return;
            }

            try stdout.print("Filters on {s}:\n", .{iface_name});
            try stdout.print("{s:<12} {s:<12} {s:<8} {s:<8} {s:<8}\n", .{ "Handle", "Parent", "Prio", "Proto", "Type" });
            try stdout.print("{s:-<12} {s:-<12} {s:-<8} {s:-<8} {s:-<8}\n", .{ "", "", "", "", "" });

            for (filters) |*f| {
                var handle_buf: [16]u8 = undefined;
                var parent_buf: [16]u8 = undefined;
                const handle_str = f.formatHandle(&handle_buf) catch "?";
                const parent_str = f.formatParent(&parent_buf) catch "?";

                const proto_str = switch (std.mem.bigToNative(u16, f.protocol)) {
                    qdisc.ETH_P.IP => "ip",
                    qdisc.ETH_P.IPV6 => "ipv6",
                    qdisc.ETH_P.ARP => "arp",
                    qdisc.ETH_P.ALL => "all",
                    else => "?",
                };

                try stdout.print("{s:<12} {s:<12} {d:<8} {s:<8} {s:<8}\n", .{
                    handle_str,
                    parent_str,
                    f.priority,
                    proto_str,
                    f.getKind(),
                });
            }
        } else if (std.mem.eql(u8, filter_cmd, "add")) {
            // wire tc <interface> filter add <type> ...
            if (filtered_args.len < 4) {
                try stdout.print("Usage: wire tc <interface> filter add <type> [options]\n", .{});
                try stdout.print("\nFilter types:\n", .{});
                try stdout.print("  u32 match ip dst <ip/mask> flowid <classid> [prio <n>]\n", .{});
                try stdout.print("  fw handle <mark> classid <classid> [prio <n>]\n", .{});
                try stdout.print("\nExamples:\n", .{});
                try stdout.print("  wire tc eth0 filter add u32 match ip dst 10.0.0.0/8 flowid 1:10\n", .{});
                try stdout.print("  wire tc eth0 filter add fw handle 1 classid 1:20 prio 1\n", .{});
                return;
            }

            const filter_type = filtered_args[3];

            if (std.mem.eql(u8, filter_type, "u32")) {
                // wire tc <interface> filter add u32 match ip dst <ip/mask> flowid <classid>
                var dst_ip: ?[4]u8 = null;
                var dst_mask: [4]u8 = .{ 255, 255, 255, 255 };
                var flowid: ?u32 = null;
                var prio: u16 = 1;

                var i: usize = 4;
                while (i < filtered_args.len) : (i += 1) {
                    if (std.mem.eql(u8, filtered_args[i], "match") and i + 4 < filtered_args.len) {
                        if (std.mem.eql(u8, filtered_args[i + 1], "ip") and std.mem.eql(u8, filtered_args[i + 2], "dst")) {
                            const ip_mask = parseIPWithMask(filtered_args[i + 3]);
                            if (ip_mask) |im| {
                                dst_ip = im.ip;
                                dst_mask = im.mask;
                            } else {
                                try stdout.print("Invalid IP/mask: {s}\n", .{filtered_args[i + 3]});
                                return;
                            }
                            i += 3;
                        }
                    } else if (std.mem.eql(u8, filtered_args[i], "flowid") and i + 1 < filtered_args.len) {
                        flowid = parseClassId(filtered_args[i + 1]) orelse {
                            try stdout.print("Invalid flowid: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                        prio = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                            try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    }
                }

                if (dst_ip == null or flowid == null) {
                    try stdout.print("Missing required options.\n", .{});
                    try stdout.print("Example: wire tc eth0 filter add u32 match ip dst 10.0.0.0/8 flowid 1:10\n", .{});
                    return;
                }

                qdisc.addU32FilterDstIP(if_index, qdisc.TC_H.make(1, 0), prio, dst_ip.?, dst_mask, flowid.?) catch |err| {
                    try stdout.print("Failed to add filter: {}\n", .{err});
                    return;
                };

                const major = qdisc.TC_H.getMajor(flowid.?);
                const minor = qdisc.TC_H.getMinor(flowid.?);
                try stdout.print("Added u32 filter on {s} -> class {d}:{d}\n", .{ iface_name, major, minor });
            } else if (std.mem.eql(u8, filter_type, "fw")) {
                // wire tc <interface> filter add fw handle <mark> classid <classid>
                var fwmark: ?u32 = null;
                var classid: ?u32 = null;
                var prio: u16 = 1;

                var i: usize = 4;
                while (i < filtered_args.len) : (i += 1) {
                    if (std.mem.eql(u8, filtered_args[i], "handle") and i + 1 < filtered_args.len) {
                        const mark_str = filtered_args[i + 1];
                        fwmark = if (mark_str.len > 2 and std.mem.eql(u8, mark_str[0..2], "0x"))
                            std.fmt.parseInt(u32, mark_str[2..], 16) catch {
                                try stdout.print("Invalid handle: {s}\n", .{mark_str});
                                return;
                            }
                        else
                            std.fmt.parseInt(u32, mark_str, 10) catch {
                                try stdout.print("Invalid handle: {s}\n", .{mark_str});
                                return;
                            };
                        i += 1;
                    } else if (std.mem.eql(u8, filtered_args[i], "classid") and i + 1 < filtered_args.len) {
                        classid = parseClassId(filtered_args[i + 1]) orelse {
                            try stdout.print("Invalid classid: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    } else if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                        prio = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                            try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                            return;
                        };
                        i += 1;
                    }
                }

                if (fwmark == null or classid == null) {
                    try stdout.print("Missing required options.\n", .{});
                    try stdout.print("Example: wire tc eth0 filter add fw handle 1 classid 1:20\n", .{});
                    return;
                }

                qdisc.addFwFilter(if_index, qdisc.TC_H.make(1, 0), prio, fwmark.?, classid.?) catch |err| {
                    try stdout.print("Failed to add filter: {}\n", .{err});
                    return;
                };

                const major = qdisc.TC_H.getMajor(classid.?);
                const minor = qdisc.TC_H.getMinor(classid.?);
                try stdout.print("Added fw filter on {s}: mark {d} -> class {d}:{d}\n", .{ iface_name, fwmark.?, major, minor });
            } else {
                try stdout.print("Unknown filter type: {s}\n", .{filter_type});
                try stdout.print("Available: u32, fw\n", .{});
            }
        } else if (std.mem.eql(u8, filter_cmd, "del") or std.mem.eql(u8, filter_cmd, "delete")) {
            // wire tc <interface> filter del prio <n> [handle <h>]
            if (filtered_args.len < 5) {
                try stdout.print("Usage: wire tc <interface> filter del prio <n> [handle <h>]\n", .{});
                try stdout.print("Example: wire tc eth0 filter del prio 1\n", .{});
                return;
            }

            var prio: ?u16 = null;
            var handle: u32 = 0;

            var i: usize = 3;
            while (i < filtered_args.len) : (i += 1) {
                if (std.mem.eql(u8, filtered_args[i], "prio") and i + 1 < filtered_args.len) {
                    prio = std.fmt.parseInt(u16, filtered_args[i + 1], 10) catch {
                        try stdout.print("Invalid priority: {s}\n", .{filtered_args[i + 1]});
                        return;
                    };
                    i += 1;
                } else if (std.mem.eql(u8, filtered_args[i], "handle") and i + 1 < filtered_args.len) {
                    const h_str = filtered_args[i + 1];
                    handle = if (h_str.len > 2 and std.mem.eql(u8, h_str[0..2], "0x"))
                        std.fmt.parseInt(u32, h_str[2..], 16) catch {
                            try stdout.print("Invalid handle: {s}\n", .{h_str});
                            return;
                        }
                    else
                        std.fmt.parseInt(u32, h_str, 10) catch {
                            try stdout.print("Invalid handle: {s}\n", .{h_str});
                            return;
                        };
                    i += 1;
                }
            }

            if (prio == null) {
                try stdout.print("Priority is required.\n", .{});
                try stdout.print("Example: wire tc eth0 filter del prio 1\n", .{});
                return;
            }

            qdisc.deleteFilter(if_index, qdisc.TC_H.make(1, 0), prio.?, handle, qdisc.ETH_P.IP) catch |err| {
                try stdout.print("Failed to delete filter: {}\n", .{err});
                return;
            };

            try stdout.print("Deleted filter with priority {d} from {s}\n", .{ prio.?, iface_name });
        } else {
            try stdout.print("Unknown filter subcommand: {s}\n", .{filter_cmd});
            try stdout.print("Available: show, add, del\n", .{});
        }
    } else {
        try stdout.print("Unknown tc subcommand: {s}\n", .{subcommand});
        try stdout.print("Available: show, add, del, class, filter\n", .{});
    }
}

/// Parse rate string like "10mbit", "1gbit", "1000000"
fn parseRate(s: []const u8) ?u64 {
    // Try to find unit suffix
    var num_end: usize = s.len;
    var multiplier: u64 = 1;

    for (s, 0..) |c, i| {
        if ((c < '0' or c > '9') and c != '.') {
            num_end = i;
            break;
        }
    }

    const num_str = s[0..num_end];
    const unit = s[num_end..];

    // Parse number
    const num = std.fmt.parseFloat(f64, num_str) catch return null;

    // Parse unit
    if (unit.len == 0 or std.mem.eql(u8, unit, "bps")) {
        multiplier = 1;
    } else if (std.mem.eql(u8, unit, "kbit") or std.mem.eql(u8, unit, "kbps")) {
        multiplier = 1000;
    } else if (std.mem.eql(u8, unit, "mbit") or std.mem.eql(u8, unit, "mbps")) {
        multiplier = 1_000_000;
    } else if (std.mem.eql(u8, unit, "gbit") or std.mem.eql(u8, unit, "gbps")) {
        multiplier = 1_000_000_000;
    } else {
        return null;
    }

    return @intFromFloat(num * @as(f64, @floatFromInt(multiplier)));
}

/// Parse size string like "32k", "1m", "1500"
fn parseSize(s: []const u8) ?u32 {
    var num_end: usize = s.len;
    var multiplier: u32 = 1;

    for (s, 0..) |c, i| {
        if (c < '0' or c > '9') {
            num_end = i;
            break;
        }
    }

    const num_str = s[0..num_end];
    const unit = s[num_end..];

    const num = std.fmt.parseInt(u32, num_str, 10) catch return null;

    if (unit.len == 0) {
        multiplier = 1;
    } else if (std.mem.eql(u8, unit, "k") or std.mem.eql(u8, unit, "K")) {
        multiplier = 1024;
    } else if (std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "M")) {
        multiplier = 1024 * 1024;
    } else {
        return null;
    }

    return num * multiplier;
}

/// IP with mask result
const IPWithMask = struct {
    ip: [4]u8,
    mask: [4]u8,
};

/// Parse IP address with optional CIDR mask (e.g., "10.0.0.0/8" or "192.168.1.1")
fn parseIPWithMask(s: []const u8) ?IPWithMask {
    // Find slash for CIDR notation
    var slash_pos: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == '/') {
            slash_pos = i;
            break;
        }
    }

    const ip_str = if (slash_pos) |pos| s[0..pos] else s;
    const mask_len: u8 = if (slash_pos) |pos|
        std.fmt.parseInt(u8, s[pos + 1 ..], 10) catch return null
    else
        32;

    // Parse IP address
    var ip: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var octet_start: usize = 0;

    for (ip_str, 0..) |c, i| {
        if (c == '.') {
            if (octet_idx >= 3) return null;
            ip[octet_idx] = std.fmt.parseInt(u8, ip_str[octet_start..i], 10) catch return null;
            octet_idx += 1;
            octet_start = i + 1;
        }
    }

    if (octet_idx != 3) return null;
    ip[3] = std.fmt.parseInt(u8, ip_str[octet_start..], 10) catch return null;

    // Calculate mask from CIDR length
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    var remaining = mask_len;
    for (0..4) |i| {
        if (remaining >= 8) {
            mask[i] = 255;
            remaining -= 8;
        } else if (remaining > 0) {
            mask[i] = @as(u8, 0xFF) << @intCast(8 - remaining);
            remaining = 0;
        }
    }

    return IPWithMask{ .ip = ip, .mask = mask };
}

/// Parse class ID string like "1:10" to u32 handle
fn parseClassId(s: []const u8) ?u32 {
    // Find the colon
    var colon_pos: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == ':') {
            colon_pos = i;
            break;
        }
    }

    if (colon_pos) |pos| {
        const major_str = s[0..pos];
        const minor_str = s[pos + 1 ..];

        const major = std.fmt.parseInt(u16, major_str, 10) catch return null;
        const minor = if (minor_str.len > 0)
            std.fmt.parseInt(u16, minor_str, 10) catch return null
        else
            0;

        return qdisc.TC_H.make(major, minor);
    } else {
        // No colon, try parsing as a simple number (minor only, major 1)
        const minor = std.fmt.parseInt(u16, s, 10) catch return null;
        return qdisc.TC_H.make(1, minor);
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
        \\Interface & Address Management:
        \\  interface                      List all interfaces
        \\  interface <name>               Show interface details
        \\  route                          Show routing table
        \\  neighbor                       Show ARP/NDP table
        \\
        \\Virtual Interfaces:
        \\  bond                           Bond interface management
        \\  bridge                         Bridge interface management
        \\  vlan                           VLAN interface management
        \\  veth                           Veth pair management
        \\  tunnel                         VXLAN/GRE tunnel management
        \\
        \\Advanced Networking:
        \\  rule                           IP policy routing rules
        \\  netns                          Network namespace management
        \\  tc                             Traffic control (qdiscs)
        \\  hw                             Hardware tuning (ethtool)
        \\
        \\Configuration:
        \\  apply <config>                 Apply configuration file
        \\  validate <config>              Validate configuration
        \\  diff <config>                  Compare config vs live state
        \\  state                          Show current network state
        \\
        \\Diagnostics:
        \\  topology                       Show network topology
        \\  diagnose                       Network diagnostics (ping, trace, capture)
        \\  trace <if> to <ip>             Trace path to destination
        \\  probe <host> <port>            Test TCP connectivity
        \\  watch <target>                 Continuous monitoring
        \\  analyze                        Analyze network configuration
        \\
        \\Daemon & History:
        \\  daemon                         Supervision daemon control
        \\  events                         Monitor network events
        \\  history                        Change history and snapshots
        \\
        \\Options:
        \\  -h, --help                     Show this help
        \\  -v, --version                  Show version
        \\
        \\Run 'wire <command>' without arguments for detailed help on each command.
        \\
    , .{});
}

test "version string" {
    try std.testing.expect(version.len > 0);
}
