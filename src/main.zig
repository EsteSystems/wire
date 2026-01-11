const std = @import("std");
const netlink_interface = @import("netlink/interface.zig");
const netlink_address = @import("netlink/address.zig");
const netlink_route = @import("netlink/route.zig");
const netlink_bond = @import("netlink/bond.zig");
const netlink_bridge = @import("netlink/bridge.zig");
const netlink_vlan = @import("netlink/vlan.zig");
const config_loader = @import("config/loader.zig");
const linux = std.os.linux;

const version = "0.2.0";

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

    // Get interfaces
    const interfaces = try netlink_interface.getInterfaces(allocator);
    defer allocator.free(interfaces);

    try stdout.print("Interfaces ({d} total)\n", .{interfaces.len});
    try stdout.print("--------------------\n", .{});

    for (interfaces) |iface| {
        const status = if (iface.isUp() and iface.hasCarrier())
            "✓"
        else if (iface.isUp())
            "⚠"
        else
            "✗";

        const addrs = try netlink_address.getAddressesForInterface(allocator, @intCast(iface.index));
        defer allocator.free(addrs);

        var addr_info: [64]u8 = undefined;
        var addr_len: usize = 0;

        if (addrs.len > 0) {
            var tmp_buf: [64]u8 = undefined;
            const addr_str = try addrs[0].formatAddress(&tmp_buf);
            @memcpy(addr_info[0..addr_str.len], addr_str);
            addr_len = addr_str.len;
        }

        const state = if (iface.isUp()) "up" else "down";
        const carrier = if (iface.hasCarrier()) "carrier" else "no-carrier";

        if (addr_len > 0) {
            try stdout.print("{s} {s}: {s}, {s}, {s}\n", .{ status, iface.getName(), state, carrier, addr_info[0..addr_len] });
        } else if (!iface.isLoopback()) {
            try stdout.print("{s} {s}: {s}, {s}, no address\n", .{ status, iface.getName(), state, carrier });
        } else {
            try stdout.print("{s} {s}: {s}, loopback\n", .{ status, iface.getName(), state });
        }
    }

    // Get routes
    const routes = try netlink_route.getRoutes(allocator);
    defer allocator.free(routes);

    try stdout.print("\nRouting\n", .{});
    try stdout.print("-------\n", .{});

    var has_default = false;
    for (routes) |route| {
        if (route.route_type != 1) continue; // Only unicast

        if (route.isDefault()) {
            has_default = true;
            var gw_buf: [64]u8 = undefined;
            const gw = try route.formatGateway(&gw_buf);
            try stdout.print("✓ default via {s}\n", .{gw});
        }
    }

    if (!has_default) {
        try stdout.print("⚠ No default route configured\n", .{});
    }

    try stdout.print("\n", .{});
}

fn handleApply(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Usage: wire apply <config-file> [--dry-run]\n", .{});
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

    const result = config_loader.applyConfig(config_path, allocator, dry_run) catch |err| {
        try stdout.print("Failed to apply configuration: {}\n", .{err});
        return;
    };

    if (!result.success) {
        std.process.exit(1);
    }
}

fn handleValidate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.print("Usage: wire validate <config-file>\n", .{});
        return;
    }

    const config_path = args[0];

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
        return;
    }

    const bridge_name = args[0];

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
        \\  vlan                           VLAN help
        \\
        \\  apply <config-file>            Apply configuration file
        \\  apply <config-file> --dry-run  Validate without applying
        \\  validate <config-file>         Validate configuration file
        \\
        \\  analyze                        Analyze network configuration
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
